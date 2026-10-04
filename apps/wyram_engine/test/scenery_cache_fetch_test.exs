defmodule Wyram.Engine.Scenery.CacheFetchTest do
  use ExUnit.Case, async: false
  alias Wyram.Block.Ref
  alias Wyram.Engine.{Native, WorldGenerator}
  alias Wyram.Engine.Scenery.{EditView, Fetch, Identity, Store}
  alias Wyram.Scenery.Key
  alias Wyram.WorldGen.{Biome, Config}

  setup do
    stone = Ref.new!("game", "stone")

    config =
      Config.new!(%{
        biomes: [Biome.new!(%{id: "wilds", surface: stone, soil: stone, rock: stone})]
      })

    blocks = %{"game:stone" => 42}
    {:ok, generation} = WorldGenerator.compile(config, 41, [], blocks)

    directory =
      Path.join(System.tmp_dir!(), "wyram-fetch-cache-#{System.unique_integer([:positive])}")

    cache = start_cache(directory)

    model = %{
      generation: generation,
      edits: EditView.new(%{}),
      stamp: 0,
      cache: cache,
      cache_identity: Identity.new(generation, blocks)
    }

    keys =
      Enum.map([{-1, -1, -1}, {0, -1, 0}], fn position ->
        {:ok, key} = Key.new(position, 1)
        key
      end)

    :erlang.trace_pattern({Native, :generate_edited_scenic_tiles, 2}, true, [:local])

    on_exit(fn ->
      :erlang.trace_pattern({Native, :generate_edited_scenic_tiles, 2}, false, [:local])
      File.rm_rf!(directory)
    end)

    {:ok, model: model, keys: keys, directory: directory}
  end

  test "a restarted disk store serves identical bytes without native generation", context do
    {cold, {:ok, first}} = traced_fetch(context.model, context.keys)
    assert length(cold) == 1
    GenServer.stop(context.model.cache)
    model = %{context.model | cache: start_cache(context.directory)}
    {warm, result} = traced_fetch(model, context.keys)
    assert result == {:ok, first}
    assert warm == []
    assert Store.stats(model.cache).hits == 2
  end

  test "unrelated edits reuse tiles and a relevant sample regenerates only its tile", context do
    {_, {:ok, first}} = traced_fetch(context.model, context.keys)
    stamp = EditView.put(context.model.edits, {500, 0, 500}, :binary.copy(<<0>>, 8192))
    model = %{context.model | stamp: stamp}
    {unchanged, result} = traced_fetch(model, context.keys)
    assert result == {:ok, first}
    assert unchanged == []
    [changed_key, _] = context.keys

    {:ok, [edited_chunk | _]} =
      Native.scenic_sample_chunks(model.generation.resource, wire(changed_key))

    stamp = EditView.put(model.edits, edited_chunk, :binary.copy(<<0>>, 8192))
    {calls, {:ok, updated}} = traced_fetch(%{model | stamp: stamp}, context.keys)
    assert [[{changed_wire, _samples}]] = calls
    assert changed_wire == wire(changed_key)
    refute hd(updated) == hd(first)
    assert List.last(updated) == List.last(first)
  end

  test "an edit while a cache read waits cannot publish the old snapshot", context do
    {_, {:ok, _}} = traced_fetch(context.model, context.keys)
    cache = context.model.cache
    :sys.suspend(cache)
    task = Task.async(fn -> Fetch.run(context.model, context.keys) end)

    try do
      await_request(cache)
      EditView.put(context.model.edits, {500, 0, 500}, :binary.copy(<<0>>, 8192))
      :sys.resume(cache)
      assert Task.await(task) == {:error, :stale}
    after
      if Process.alive?(cache), do: :sys.resume(cache)
    end
  end

  test "a stopped cache owner falls back to generation with the same bytes", context do
    {_, {:ok, expected}} = traced_fetch(context.model, context.keys)
    GenServer.stop(context.model.cache)
    {calls, result} = traced_fetch(context.model, context.keys)
    assert length(calls) == 1
    assert result == {:ok, expected}
  end

  defp await_request(cache, attempts \\ 100)
  defp await_request(_, 0), do: flunk("cache read was never queued")

  defp await_request(cache, attempts) do
    {:messages, messages} = Process.info(cache, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, {:get, _}}, &1)) do
      :ok
    else
      Process.sleep(2)
      await_request(cache, attempts - 1)
    end
  end

  defp start_cache(directory),
    do:
      start_supervised!(
        Supervisor.child_spec(
          {Store, name: nil, directory: directory, max_bytes: 1_000_000, max_entries: 8},
          id: make_ref(),
          restart: :temporary
        )
      )

  defp traced_fetch(model, keys) do
    owner = self()

    worker =
      spawn(fn ->
        receive do: (:run -> send(owner, {:fetch_result, self(), Fetch.run(model, keys)}))
        receive do: (:stop -> :ok)
      end)

    :erlang.trace(worker, true, [:call, {:tracer, owner}])
    send(worker, :run)
    assert_receive {:fetch_result, ^worker, result}, 5_000
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}
    calls = collect_calls(worker, [])
    send(worker, :stop)
    {Enum.reverse(calls), result}
  end

  defp collect_calls(worker, calls) do
    receive do
      {:trace, ^worker, :call, {Native, :generate_edited_scenic_tiles, [_resource, inputs]}} ->
        collect_calls(worker, [inputs | calls])
    after
      0 -> calls
    end
  end

  defp wire(key), do: {key.position, key.level}
end
