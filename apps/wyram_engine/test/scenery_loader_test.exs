defmodule Wyram.Engine.Scenery.LoaderTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.Loader
  alias Wyram.Scenery.{Config, Key}

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, supervisor: supervisor}
  end

  test "work stays bounded across view resets and old view results are discarded", %{
    supervisor: supervisor
  } do
    owner = self()

    fetch = fn keys ->
      send(owner, {:started, self(), keys})
      receive do: (:finish -> {:ok, Enum.map(keys, &empty/1)})
    end

    keys = Enum.map(0..5, &key/1)

    loader =
      Loader.new(Config.new!(%{}))
      |> Loader.reset(plan(keys), 0)
      |> Loader.dispatch(supervisor, fetch)

    assert map_size(loader.tasks) == 2
    assert_receive {:started, one, batch_one}
    assert_receive {:started, two, batch_two}
    assert length(batch_one) == 2 and length(batch_two) == 2
    loader = Loader.reset(loader, plan([key(100)]), 0) |> Loader.dispatch(supervisor, fetch)
    assert map_size(loader.tasks) == 2
    refute_receive {:started, _, _}, 20
    send(one, :finish)
    assert_receive {ref, result}
    {loader, accepted} = Loader.complete(loader, ref, result)
    assert accepted == []
    assert loader.cache == %{}
    loader = Loader.dispatch(loader, supervisor, fetch)
    assert map_size(loader.tasks) == 2
    assert_receive {:started, three, [wanted]}
    assert wanted == key(100)
    send(three, :finish)
    assert_receive {ref, result}
    {loader, accepted} = Loader.complete(loader, ref, result)
    assert accepted == [{wanted, empty(wanted)}]
    assert loader.cache == Map.new(accepted)
    send(two, :finish)
    assert_receive {ref, result}
    {loader, []} = Loader.complete(loader, ref, result)
    assert map_size(loader.tasks) == 0
    assert loader.cache == Map.new(accepted)
  end

  test "camera changes reuse valid cache but edit revisions reject even still-wanted old jobs", %{
    supervisor: supervisor
  } do
    owner = self()

    fetch = fn keys ->
      send(owner, {:started, self(), keys})
      receive do: (:finish -> {:ok, Enum.map(keys, &empty/1)})
    end

    keys = [key(0), key(1)]

    loader =
      Loader.new(Config.new!(%{}))
      |> Loader.reset(plan(keys), 0)
      |> Loader.dispatch(supervisor, fetch)

    assert_receive {:started, worker, ^keys}
    loader = Loader.reset(loader, plan(keys), 1)
    send(worker, :finish)
    assert_receive {ref, result}
    {loader, []} = Loader.complete(loader, ref, result)
    assert loader.cache == %{}
    loader = Loader.dispatch(loader, supervisor, fetch)
    assert_receive {:started, worker, ^keys}
    send(worker, :finish)
    assert_receive {ref, result}
    {loader, accepted} = Loader.complete(loader, ref, result)
    assert length(accepted) == 2

    loader =
      Loader.reset(loader, plan(Enum.reverse(keys)), 1) |> Loader.dispatch(supervisor, fetch)

    assert loader.pending == []
    assert map_size(loader.tasks) == 0
    assert map_size(loader.cache) == 2
    refute_receive {:started, _, _}, 20
    loader = Loader.reset(loader, plan([key(0)]), 1)
    assert Map.keys(loader.cache) == [key(0)]
  end

  test "failed or mismatched native batches do not enter the cache", %{supervisor: supervisor} do
    for result <- [{:error, "failed"}, {:ok, []}, {:ok, [empty(key(99))]}, {:ok, [<<0>>]}] do
      fetch = fn _ -> result end

      loader =
        Loader.new(Config.new!(%{}))
        |> Loader.reset(plan([key(0)]), 0)
        |> Loader.dispatch(supervisor, fetch)

      assert_receive {ref, ^result}
      {loader, {:error, _}} = Loader.complete(loader, ref, result)
      assert loader.cache == %{}
      assert map_size(loader.tasks) == 0
      assert {loader, []} == Loader.complete(loader, ref, result)
    end
  end

  test "a view reset does not redispatch still-wanted work that completes afterward", %{
    supervisor: supervisor
  } do
    owner = self()

    fetch = fn keys ->
      send(owner, {:started, self(), keys})
      receive do: (:finish -> {:ok, Enum.map(keys, &empty/1)})
    end

    keys = [key(0), key(1)]

    loader =
      Loader.new(Config.new!(%{}))
      |> Loader.reset(plan(keys), 0)
      |> Loader.dispatch(supervisor, fetch)

    assert_receive {:started, worker, ^keys}
    loader = Loader.reset(loader, plan(Enum.reverse(keys)), 0)
    send(worker, :finish)
    assert_receive {ref, result}
    {loader, accepted} = Loader.complete(loader, ref, result)
    assert length(accepted) == 2
    loader = Loader.dispatch(loader, supervisor, fetch)
    assert loader.pending == []
    assert map_size(loader.tasks) == 0
    refute_receive {:started, _, _}, 20
  end

  defp key(x), do: %Key{position: {x, 0, 0}, level: 1}
  defp plan(keys), do: %{nodes: Map.new(keys, &{&1, []}), order: keys}

  defp empty(%Key{position: {x, y, z}, level: level}),
    do: <<"WSL1", level, 0, 0, 0, x::little-signed-32, y::little-signed-32, z::little-signed-32>>
end
