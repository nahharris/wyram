defmodule Wyram.Engine.ClientPort do
  @moduledoc "Bounded binary transport to the native graphics client."
  use GenServer
  require Logger
  alias Wyram.Character.Profile
  alias Wyram.Engine.{Paths, PluginManager, World}

  @radius 2
  @chunk_side 16

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec publish_chunk({integer(), integer(), integer()}, non_neg_integer(), binary()) :: :ok
  def publish_chunk(key, revision, data) do
    GenServer.cast(__MODULE__, {:publish_chunk, key, revision, data})
  end

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec await_exit() :: {:ok, non_neg_integer()} | {:error, :client_unavailable}
  def await_exit, do: GenServer.call(__MODULE__, :await_exit, :infinity)

  def teleport(x, y, z, yaw, pitch),
    do: GenServer.call(__MODULE__, {:teleport, x, y, z, yaw, pitch})

  @impl true
  def init(_) do
    executable = Paths.client_executable()
    profile = PluginManager.player_profile()

    if File.regular?(executable) do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          {:packet, 4},
          :hide
        ])

      state = initial_state(port, profile)
      send(self(), :initialize)
      {:ok, state}
    else
      Logger.warning("Native client unavailable at #{executable}; engine running headlessly")
      {:ok, initial_state(nil, profile)}
    end
  end

  @impl true
  def handle_info(:initialize, state) do
    send_packet(state.port, %{
      type: "hello",
      blocks: PluginManager.blocks(),
      colors: PluginManager.block_colors(),
      motion: state.motion
    })

    {:noreply, stream(state, {0, 0})}
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case Jason.decode(bytes) do
      {:ok, packet} -> {:noreply, handle_packet(packet, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0, do: Logger.warning("Native client exited with status #{status}")
    Enum.each(state.exit_waiters, &GenServer.reply(&1, {:ok, status}))

    {:noreply,
     %{state | port: nil, sent: MapSet.new(), player: nil, exit_status: status, exit_waiters: []}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{connected: state.port != nil, player: state.player}, state}
  end

  def handle_call(:await_exit, _from, %{exit_status: status} = state) when is_integer(status) do
    {:reply, {:ok, status}, state}
  end

  def handle_call(:await_exit, _from, %{port: nil} = state) do
    {:reply, {:error, :client_unavailable}, state}
  end

  def handle_call(:await_exit, from, state) do
    {:noreply, %{state | exit_waiters: [from | state.exit_waiters]}}
  end

  def handle_call({:teleport, _, _, _, _, _}, _from, %{port: nil} = state) do
    {:reply, {:error, :client_unavailable}, state}
  end

  def handle_call({:teleport, x, y, z, yaw, pitch}, _from, state) do
    send_packet(state.port, %{type: "teleport", x: x, y: y, z: z, yaw: yaw, pitch: pitch})
    motion = Profile.motion(state.profile, false)
    send_packet(state.port, Map.put(motion, :type, :motion))
    {:reply, :ok, %{state | motion: motion}}
  end

  @impl true
  def handle_cast({:publish_chunk, key, revision, data}, state) do
    if MapSet.member?(state.sent, key) do
      send_chunk(state.port, key, revision, data)
    end

    {:noreply, state}
  end

  defp handle_packet(%{"type" => "movement_intent", "running" => running}, state)
       when is_boolean(running) do
    motion = Profile.motion(state.profile, running)
    if motion != state.motion, do: send_packet(state.port, Map.put(motion, :type, :motion))
    %{state | motion: motion}
  end

  defp handle_packet(
         %{"type" => "player", "x" => x, "y" => y, "z" => z, "yaw" => yaw, "pitch" => pitch},
         state
       )
       when is_number(x) and is_number(y) and is_number(z) and is_number(yaw) and is_number(pitch) do
    center = {Integer.floor_div(floor(x), @chunk_side), Integer.floor_div(floor(z), @chunk_side)}
    player = %{x: x, y: y, z: z, yaw: yaw, pitch: pitch}
    %{stream(state, center) | player: player}
  end

  defp handle_packet(%{"type" => "view", "x" => x, "z" => z}, state)
       when is_number(x) and is_number(z) do
    stream(
      state,
      {Integer.floor_div(trunc(x), @chunk_side), Integer.floor_div(trunc(z), @chunk_side)}
    )
  end

  defp handle_packet(%{"type" => "edit", "x" => x, "y" => y, "z" => z, "id" => id}, state)
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(id) do
    World.set_block(x, y, z, id)
    state
  end

  defp handle_packet(_, state), do: state

  defp initial_state(port, profile) do
    %{
      port: port,
      sent: MapSet.new(),
      center: {0, 0},
      player: nil,
      exit_status: nil,
      exit_waiters: [],
      profile: profile,
      motion: Profile.motion(profile, false)
    }
  end

  defp stream(%{port: nil} = state, _), do: state

  defp stream(state, {cx, cz} = center) do
    wanted =
      MapSet.new(
        for x <- (cx - @radius)..(cx + @radius),
            z <- (cz - @radius)..(cz + @radius),
            y <- 3..5,
            do: {x, y, z}
      )

    Enum.each(MapSet.difference(state.sent, wanted), fn key ->
      send_packet(state.port, %{type: "forget", key: Tuple.to_list(key)})
    end)

    Enum.each(MapSet.difference(wanted, state.sent), fn {x, y, z} = key ->
      %{data: data, revision: revision} = World.get_chunk(x, y, z)
      send_chunk(state.port, key, revision, data)
    end)

    %{state | sent: wanted, center: center}
  end

  defp send_chunk(port, key, revision, data) do
    send_packet(port, %{
      type: "chunk",
      key: Tuple.to_list(key),
      revision: revision,
      data: Base.encode64(data)
    })
  end

  defp send_packet(nil, _packet), do: :ok
  defp send_packet(port, packet), do: Port.command(port, Jason.encode!(packet))
end
