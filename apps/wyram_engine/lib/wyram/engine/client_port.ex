defmodule Wyram.Engine.ClientPort do
  @moduledoc "Bounded binary transport to the native graphics client."
  use GenServer
  require Logger

  alias Wyram.Engine.{Characters, Native, Paths, PluginManager, World}

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
    Process.flag(:trap_exit, true)
    executable = Paths.client_executable()

    if File.regular?(executable) do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          {:packet, 4},
          :hide
        ])

      state = initial_state(port)
      send(self(), :initialize)
      {:ok, state}
    else
      Logger.warning("Native client unavailable at #{executable}; engine running headlessly")
      {:ok, initial_state(nil)}
    end
  end

  @impl true
  def handle_info(:initialize, state) do
    send_packet(state.port, %{
      type: "hello",
      blocks: PluginManager.blocks(),
      colors: PluginManager.block_colors(),
      characters: Characters.latest()
    })

    Characters.connect()
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
    Characters.disconnect()
    Enum.each(state.exit_waiters, &GenServer.reply(&1, {:ok, status}))

    {:noreply,
     %{state | port: nil, sent: MapSet.new(), player: nil, exit_status: status, exit_waiters: []}}
  end

  def handle_info(:poll_client, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:poll_client, state) do
    case Native.process_status(state.process_watch) do
      {:ok, nil} ->
        Process.send_after(self(), :poll_client, 100)
        {:noreply, state}

      {:ok, status} ->
        handle_info({state.port, {:exit_status, status}}, state)

      {:error, reason} ->
        {:stop, {:client_monitor_failed, reason}, state}
    end
  end

  def handle_info({port, {:exit_status, _}}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    # Keep await_exit waiters alive until the native exit_status arrives.
    {:noreply, state}
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
    case Characters.teleport(x, y, z, yaw, pitch) do
      :ok ->
        send_packet(state.port, %{type: "character_states", characters: Characters.latest()})
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:publish_chunk, key, revision, data}, state) do
    if MapSet.member?(state.sent, key) do
      send_chunk(state.port, key, revision, data)
    end

    {:noreply, state}
  end

  def handle_cast(:characters_restarted, state) do
    if state.port != nil, do: Characters.connect()
    {:noreply, state}
  end

  def handle_cast(:characters_ready, state) do
    batch = Characters.latest()
    Characters.acknowledge()
    send_packet(state.port, %{type: "character_states", characters: batch})
    player = Enum.find(batch, &(&1.id == "player"))
    {x, z} = {player.x, player.z}
    center = {Integer.floor_div(floor(x), @chunk_side), Integer.floor_div(floor(z), @chunk_side)}
    next = if state.center != center, do: stream(state, center), else: state
    {:noreply, %{next | player: player}}
  end

  defp handle_packet(%{"type" => "input"} = packet, state) do
    Characters.input(packet)
    state
  end

  defp handle_packet(%{"type" => "edit", "x" => x, "y" => y, "z" => z, "id" => id}, state)
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(id) do
    World.set_block(x, y, z, id)
    state
  end

  defp handle_packet(_, state), do: state

  defp initial_state(port) do
    watch =
      if port != nil do
        {:os_pid, pid} = Port.info(port, :os_pid)

        case Native.watch_process(pid) do
          {:ok, watch} ->
            Process.send_after(self(), :poll_client, 100)
            watch

          {:error, _} ->
            nil
        end
      end

    %{
      port: port,
      sent: MapSet.new(),
      center: {0, 0},
      player: nil,
      exit_status: nil,
      exit_waiters: [],
      process_watch: watch
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

  defp send_packet(port, packet) do
    Port.command(port, Jason.encode!(packet))
  rescue
    ArgumentError -> {:error, :client_closed}
  end
end
