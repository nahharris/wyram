defmodule Wyram.Engine.CharacterMotionTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.Profile
  alias Wyram.Engine.ClientPort

  test "movement intents resolve on Elixir and never accept client speed values" do
    state = %{
      port: nil,
      profile: Profile.default(),
      motion: Profile.motion(Profile.default(), false)
    }

    packet = Jason.encode!(%{type: "movement_intent", running: true, speed: 1000})
    assert {:noreply, next} = ClientPort.handle_info({nil, {:data, packet}}, state)
    assert next.motion.mode == :run
    assert next.motion.speed == 9.0
    packet = Jason.encode!(%{type: "movement_intent", running: false})
    assert {:noreply, walking} = ClientPort.handle_info({nil, {:data, packet}}, next)
    assert walking.motion.mode == :walk
    assert walking.motion.speed == 5.0
  end

  test "invalid intents do not change character motion" do
    state = %{
      port: nil,
      profile: Profile.default(),
      motion: Profile.motion(Profile.default(), false)
    }

    for running <- [nil, "true", 1, %{}] do
      packet = Jason.encode!(%{type: "movement_intent", running: running})
      assert {:noreply, ^state} = ClientPort.handle_info({nil, {:data, packet}}, state)
    end
  end
end
