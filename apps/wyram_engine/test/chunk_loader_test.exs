defmodule Wyram.Engine.ChunkLoaderTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.{ChunkLoader, ClientPort}

  test "blocked region requests are bounded and leave the coordinator responsive" do
    owner = self()

    fetch = fn keys ->
      send(owner, {:fetch, self(), keys})

      receive do
        :release -> Enum.map(keys, &{&1, %{revision: 0, data: <<0>>}})
      end
    end

    keys = for x <- [0, 4, 8, 12], y <- 0..31, do: {x, y, 0}
    loader = ChunkLoader.new() |> ChunkLoader.reset(keys) |> ChunkLoader.dispatch(fetch)
    on_exit(fn -> ChunkLoader.cancel(loader) end)
    assert map_size(loader.tasks) == 4

    batches =
      for _ <- 1..4 do
        assert_receive {:fetch, pid, batch}
        assert length(batch) == 16
        {pid, batch}
      end

    assert batches
           |> Enum.map(fn {_, [{x, _, _} | _]} -> div(x, 4) end)
           |> Enum.uniq()
           |> length() == 4

    assert {:reply, %{connected: false, player: nil}, _} =
             ClientPort.handle_call(:snapshot, nil, %{port: nil, player: nil})

    {pid, _} = hd(batches)
    send(pid, :release)
    assert_receive {ref, chunks}
    {loader, accepted} = ChunkLoader.complete(loader, ref, chunks)
    assert length(accepted) == 16
    loader = ChunkLoader.dispatch(loader, fetch)
    assert map_size(loader.tasks) == 4
    ChunkLoader.cancel(loader)
  end

  test "an edit received while a snapshot is pending wins over that snapshot" do
    owner = self()

    fetch = fn keys ->
      send(owner, {:fetch, self()})

      receive do
        :release -> Enum.map(keys, &{&1, %{revision: 0, data: <<0>>}})
      end
    end

    loader = ChunkLoader.new() |> ChunkLoader.reset([{0, 0, 0}]) |> ChunkLoader.dispatch(fetch)
    assert_receive {:fetch, pid}
    {loader, true} = ChunkLoader.publish(loader, {0, 0, 0}, 1)
    send(pid, :release)
    assert_receive {ref, chunks}
    {loader, []} = ChunkLoader.complete(loader, ref, chunks)
    assert loader.revisions[{0, 0, 0}] == 1
    assert {_, false} = ChunkLoader.publish(loader, {99, 0, 99}, 2)
  end

  test "view replacement cancels obsolete requests and ignores late results" do
    owner = self()

    fetch = fn _ ->
      send(owner, {:fetch, self()})

      receive do
        :release -> []
      end
    end

    loader = ChunkLoader.new() |> ChunkLoader.reset([{0, 0, 0}]) |> ChunkLoader.dispatch(fetch)
    assert_receive {:fetch, pid}
    [ref] = Map.keys(loader.tasks)
    monitor = Process.monitor(pid)
    loader = ChunkLoader.reset(loader, [{4, 0, 0}])
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {^loader, []} =
             ChunkLoader.complete(loader, ref, [{{0, 0, 0}, %{revision: 0, data: <<0>>}}])

    assert loader.pending == [{4, 0, 0}]
    assert loader.tasks == %{}
  end
end
