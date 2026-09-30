defmodule Wyram.Engine.CharacterMotionTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.ClientPort

  test "client position and speed claims cannot replace authoritative player state" do
    state = %{port: nil, player: nil}

    for packet <- [
          %{type: "player", x: 1000, y: 1000, z: 1000, yaw: 0, pitch: 0},
          %{type: "movement_intent", running: true, speed: 1000}
        ] do
      assert {:noreply, ^state} =
               ClientPort.handle_info({nil, {:data, Jason.encode!(packet)}}, state)
    end
  end
end
