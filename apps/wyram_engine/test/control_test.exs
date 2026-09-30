defmodule Wyram.Engine.ControlTest do
  use ExUnit.Case, async: false

  alias Wyram.Engine.{ClientPort, Control, Paths, PluginManager, World}

  test "loopback control authenticates commands and inspects blocks by name" do
    directory = Path.join(Paths.data_dir(), "control-test")
    File.mkdir_p!(directory)
    pid = start_supervised!({Control, directory: directory, port: 0})
    endpoint = directory |> Path.join("control.json") |> File.read!() |> Jason.decode!()

    assert %{"ok" => true, "plugins" => plugins, "client_connected" => false} =
             request(endpoint, %{"op" => "status"})

    assert plugins == %{"test_terrain" => "0.1.0", "test_addon" => "0.1.0"}

    assert %{"ok" => false, "error" => "unauthorized"} =
             request(endpoint, %{"op" => "status", "token" => "wrong"})

    id = PluginManager.blocks()["test_addon:prism"]

    assert %{"ok" => true} =
             request(endpoint, %{
               "op" => "set_block",
               "x" => 8,
               "y" => 80,
               "z" => 8,
               "block" => "test_addon:prism"
             })

    assert World.get_block(8, 80, 8) == id

    assert %{"ok" => true, "blocks" => blocks} =
             request(endpoint, %{"op" => "inspect", "at" => [8, 80, 8], "radius" => 1})

    assert Enum.any?(blocks, fn block ->
             block == %{"x" => 8, "y" => 80, "z" => 8, "id" => id, "name" => "test_addon:prism"}
           end)

    send(
      ClientPort,
      {nil,
       {:data, Jason.encode!(%{type: "player", x: 8.5, y: 80.5, z: 8.5, yaw: 1.0, pitch: 0.0})}}
    )

    assert ClientPort.snapshot().player == nil

    assert %{"ok" => false, "error" => "no_player"} =
             request(endpoint, %{"op" => "inspect", "radius" => 0})

    assert %{"ok" => false, "error" => "invalid_request"} =
             request(endpoint, %{"op" => "inspect", "at" => [8, 80, 8], "radius" => 10})

    assert %{"ok" => false, "error" => "client_unavailable"} =
             request(endpoint, %{"op" => "teleport", "x" => 0, "y" => 80, "z" => 0})

    assert Process.alive?(pid)
  end

  defp request(endpoint, command) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", endpoint["port"], [:binary, packet: :line, active: false])

    payload = Map.put_new(command, "token", endpoint["token"])
    :ok = :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    Jason.decode!(line)
  end
end
