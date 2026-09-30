defmodule Wyram.Engine.CharactersTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.Profile
  alias Wyram.Engine.Characters

  defp intent(sequence, epoch) do
    %{
      "sequence" => sequence,
      "epoch" => epoch,
      "forward" => 1.0,
      "right" => 0.0,
      "yaw" => 0.0,
      "pitch" => 0.0,
      "running" => true,
      "jump" => false
    }
  end

  test "one owner rejects stale input and teleport-invalidated epochs" do
    collision = fn queries ->
      {:ok,
       Enum.map(queries, fn {{x, y, z}, {dx, dy, dz}, _, _} ->
         {{x + dx, y + dy, z + dz}, {false, false, false}, false}
       end)}
    end

    pid =
      start_supervised!(
        {Characters,
         name: nil,
         tick: false,
         profile: Profile.default(),
         collision: collision,
         publish: fn _ -> :ok end}
      )

    Characters.connect(pid)
    Characters.input(intent(2, 0), pid)
    Characters.input(intent(1, 0), pid)
    send(pid, :tick)
    snapshot = Characters.snapshot(pid)
    assert snapshot.input_sequence == 2
    assert snapshot.z < 0.5
    assert :ok = Characters.teleport(10.0, 80.0, 10.0, 0.0, 0.0, pid)
    Characters.input(intent(100, 0), pid)
    send(pid, :tick)
    teleported = Characters.snapshot(pid)
    assert teleported.epoch == 1
    assert teleported.input_sequence == 0
    assert_in_delta teleported.z, 10.0, 1.0e-9
  end
end
