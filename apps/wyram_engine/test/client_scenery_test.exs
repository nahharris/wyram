defmodule Wyram.Engine.ClientSceneryTest do
  use ExUnit.Case, async: false
  alias Wyram.Engine.{ClientPort, Scenery}
  alias Wyram.Engine.Scenery.{Transport, Wire}
  alias Wyram.Scenery.{Config, Key}

  defmodule Collector do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: Scenery)
    def init(owner), do: {:ok, owner}

    def handle_cast(message, owner) do
      send(owner, {:service, message})
      {:noreply, owner}
    end
  end

  test "the coordinator writes packed plans and tiles to a real port and maps native credit" do
    assert Process.whereis(Scenery) == nil
    start_supervised!({Collector, self()})

    port =
      Port.open({:spawn_executable, System.find_executable("powershell.exe")}, [
        :binary,
        :exit_status,
        :hide,
        {:packet, 4},
        {:args,
         [
           "-NoProfile",
           "-NonInteractive",
           "-Command",
           "[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())"
         ]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    state = %{
      port: port,
      scenery_protocol: 0,
      chunk_protocol: 0,
      scenery: %Transport{},
      center: {-2, 3, 0}
    }

    legacy = Jason.encode!(%{type: "capabilities", chunk_protocol: 1, scenery_protocol: 1})
    assert {:noreply, legacy_state} = ClientPort.handle_info({port, {:data, legacy}}, state)
    assert legacy_state.scenery_protocol == 0
    refute_receive {:service, {:view, _, _}}, 10
    capabilities = Jason.encode!(%{type: "capabilities", chunk_protocol: 1, scenery_protocol: 2})
    assert {:noreply, active} = ClientPort.handle_info({port, {:data, capabilities}}, state)
    assert_receive {:service, {:view, client, {-24, 56, 8}}}
    assert client == self()
    {:ok, key} = Key.new({-1, 0, 2}, 1)
    plan = %{roots: [key], order: [key], nodes: %{key => []}, content: 7}
    config = Config.new!(%{})

    assert {:noreply, planned} =
             ClientPort.handle_info({:scenery_plan, 3, 0, plan, config}, active)

    expected = Wire.plan(3, 0, plan, config) |> IO.iodata_to_binary()
    assert_receive {^port, {:data, ^expected}}, 5000
    tile = <<"WSL1", 1, 0, 0, 0, -1::little-signed-32, 0::little-signed-32, 2::little-signed-32>>
    token = make_ref()

    assert {:noreply, waiting} =
             ClientPort.handle_info({:scenery_tiles, 3, token, [{key, tile}]}, planned)

    assert_receive {^port, {:data, packet}}, 5000
    assert <<"WST1", 3::64, delivery::64, _::binary>> = packet
    assert packet == Wire.tiles(3, delivery, [{key, tile}]) |> IO.iodata_to_binary()
    credit = Jason.encode!(%{type: "scenery_ready", epoch: 3, delivery: delivery})
    assert {:noreply, released} = ClientPort.handle_info({port, {:data, credit}}, waiting)
    assert released.scenery.waiting == nil
    assert_receive {:service, {:acknowledge, 3, ^token}}
    assert {:noreply, ^released} = ClientPort.handle_info({port, {:data, credit}}, released)
    refute_receive {:service, {:acknowledge, _, _}}, 10
    capabilities = Jason.encode!(%{type: "capabilities", chunk_protocol: 1, scenery_protocol: 3})

    assert {:noreply, revisioned} =
             ClientPort.handle_info({port, {:data, capabilities}}, released)

    assert revisioned.scenery_protocol == 3
    assert_receive {:service, {:view, ^client, {-24, 56, 8}}}
    updated = Map.merge(plan, %{content: 8, lineage: 7, revisions: %{key => 0}})

    assert {:noreply, _} =
             ClientPort.handle_info({:scenery_plan, 4, 1, updated, config}, revisioned)

    packet = Wire.plan(4, 1, updated, config, 3) |> IO.iodata_to_binary()
    assert_receive {^port, {:data, ^packet}}, 5000
    assert <<"WSP2", 4::64, 7::64, 1::64, _::binary>> = packet
    Scenery.disconnect(Scenery, self())
    assert_receive {:service, {:disconnect, ^client}}
  end
end
