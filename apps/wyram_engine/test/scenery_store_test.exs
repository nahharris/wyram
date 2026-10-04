defmodule Wyram.Engine.Scenery.StoreTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.Store
  alias Wyram.Scenery.Key

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wyram-tile-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "tiles survive a store restart and mismatched content never hits", %{directory: directory} do
    cache = start_cache(directory)
    entry = empty(0)
    assert :ok = Store.put(cache, [entry])
    assert Store.get(cache, [request(entry)]) == [elem(entry, 2)]
    GenServer.stop(cache)
    restored = start_cache(directory)
    assert Store.get(restored, [request(entry)]) == [elem(entry, 2)]
    assert Store.get(restored, [{digest(:different_world), elem(entry, 1)}]) == [nil]
    assert Store.get(restored, [{elem(entry, 0), key(1)}]) == [nil]
  end

  test "eviction obeys byte and entry limits before and after policy shrink", %{
    directory: directory
  } do
    cache = start_cache(directory, max_entries: 2, max_bytes: 300)
    [one, two, three] = Enum.map(0..2, &empty/1)
    assert :ok = Store.put(cache, [one, two])
    assert Store.get(cache, [request(one)]) == [elem(one, 2)]
    assert :ok = Store.put(cache, [three])
    assert Store.get(cache, [request(one), request(two)]) == [elem(one, 2), nil]
    assert Store.get(cache, [request(three)]) == [elem(three, 2)]
    assert Store.stats(cache).entries == 2
    assert disk_bytes(directory) <= 300
    GenServer.stop(cache)
    smaller = start_cache(directory, max_entries: 1, max_bytes: 100)
    assert Store.stats(smaller).entries <= 1
    assert Store.stats(smaller).bytes <= 100
    assert disk_bytes(directory) <= 100
  end

  test "corrupt, truncated and future-version files become misses", %{directory: directory} do
    cache = start_cache(directory)
    entry = empty(0)
    assert :ok = Store.put(cache, [entry])
    GenServer.stop(cache)
    [name] = directory |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tile"))
    file = Path.join(directory, name)
    valid = File.read!(file)

    for damaged <- [
          <<"WSC9">> <> binary_part(valid, 4, byte_size(valid) - 4),
          <<1, 2, 3>>,
          binary_part(valid, 0, byte_size(valid) - 1) <> <<1>>
        ] do
      File.write!(file, damaged)
      restored = start_cache(directory)
      assert Store.get(restored, [request(entry)]) == [nil]
      GenServer.stop(restored)
    end
  end

  test "invalid packed cells and oversized batches do not enter storage", %{directory: directory} do
    cache = start_cache(directory)
    {identity, key, _} = empty(0)

    invalid =
      <<"WSL1", 1, 1, 0, 0, 0::little-32, 0::little-32, 0::little-32, 42::little-16,
        999::little-32, 1, 0>>

    assert {:error, _} = Store.put(cache, [{identity, key, invalid}])
    assert {:error, _} = Store.put(cache, Enum.map(0..2, &empty/1))
    assert Store.get(cache, [{identity, key}]) == [nil]
    assert Store.stats(cache).entries == 0
    assert {:error, _} = Store.get(cache, Enum.map(0..2, &request(empty(&1))))
  end

  test "a cache directory failure stays optional and preserves unrelated files", %{
    directory: directory
  } do
    File.mkdir_p!(directory)
    unrelated = Path.join(directory, "unrelated.txt")
    File.write!(unrelated, "keep")
    cache = start_cache(directory)
    assert :ok = Store.put(cache, [empty(0)])
    assert File.read!(unrelated) == "keep"
    unavailable = start_cache(unrelated)
    assert Store.get(unavailable, [request(empty(0))]) == [nil]
    assert {:error, _} = Store.put(unavailable, [empty(0)])
    assert File.read!(unrelated) == "keep"
  end

  test "a slow owner retains caller backpressure instead of accumulating timed-out requests", %{
    directory: directory
  } do
    cache = start_cache(directory)
    :sys.suspend(cache)
    caller = Task.async(fn -> Store.get(cache, [request(empty(0))]) end)

    try do
      assert Task.yield(caller, 5_200) == nil
      :sys.resume(cache)
      assert Task.await(caller) == [nil]
    after
      if Process.alive?(cache), do: :sys.resume(cache)
    end
  end

  defp start_cache(directory, options \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Store,
         Keyword.merge(
           [name: nil, directory: directory, max_bytes: 1_000, max_entries: 4],
           options
         )},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  defp empty(x) do
    {digest(x), key(x), <<"WSL1", 1, 0, 0, 0, x::little-signed-32, 0::little-32, 0::little-32>>}
  end

  defp key(x) do
    {:ok, key} = Key.new({x, 0, 0}, 1)
    key
  end

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value))
  defp request({identity, key, _}), do: {identity, key}

  defp disk_bytes(directory),
    do:
      directory
      |> File.ls!()
      |> Enum.map(&File.stat!(Path.join(directory, &1)).size)
      |> Enum.sum()
end
