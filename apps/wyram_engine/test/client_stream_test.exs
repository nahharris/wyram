defmodule Wyram.Engine.ClientStreamTest do
  use ExUnit.Case, async: false
  alias Wyram.Engine.{ChunkLoader, ClientPort, World}

  test "the actual client coordinator answers while its region owner is suspended" do
    region = World.region_pid(400, 400)
    original = :sys.get_state(ClientPort)
    :ok = :sys.suspend(region)
    ref = make_ref()

    :sys.replace_state(ClientPort, fn state ->
      %{
        state
        | port: make_ref(),
          stream_ref: ref,
          loader: ChunkLoader.new() |> ChunkLoader.reset([{400, 0, 400}])
      }
    end)

    try do
      send(ClientPort, {:stream_batch, ref})
      caller = Task.async(fn -> ClientPort.snapshot() end)
      assert %{connected: true} = Task.await(caller, 1_000)
      assert map_size(:sys.get_state(ClientPort).loader.tasks) == 1
    after
      :sys.replace_state(ClientPort, fn state ->
        ChunkLoader.cancel(state.loader)
        original
      end)

      :sys.resume(region)
    end
  end
end
