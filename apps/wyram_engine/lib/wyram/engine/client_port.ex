defmodule Wyram.Engine.ClientPort do
  @moduledoc "Bounded binary transport to the native graphics client."
  use GenServer
  require Logger

  alias Wyram.Engine.{
    Characters,
    ChunkLoader,
    ChunkStream,
    ChunkWire,
    Native,
    Paths,
    PluginManager,
    Scenery,
    World,
    WorldGenerator
  }

  alias Wyram.Engine.Scenery.Transport

  @radius 4
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
    blocks = PluginManager.blocks()
    descriptors = PluginManager.render_descriptors()

    send_packet(state.port, %{
      type: "hello",
      blocks: blocks,
      colors: PluginManager.block_colors(),
      descriptors: descriptors,
      scenery_planes:
        WorldGenerator.scenery_planes(PluginManager.worldgen(), blocks, descriptors),
      noncolliding: PluginManager.noncolliding(),
      placeable: PluginManager.placeable() |> Enum.sort() |> Enum.map(&elem(&1, 1)),
      characters: Characters.latest(),
      models: PluginManager.character_models()
    })

    Characters.connect()
    player = Enum.find(Characters.latest(), &(&1.id == "player"))
    {:noreply, stream(state, center(player))}
  end

  def handle_info({:stream_batch, ref}, %{stream_ref: ref, port: port} = state)
      when not is_nil(port) do
    {:noreply, %{state | loader: ChunkLoader.dispatch(state.loader)}}
  end

  def handle_info({:stream_batch, _}, state), do: {:noreply, state}

  def handle_info(:scenery_ready, state), do: {:noreply, request_scenery(state)}

  def handle_info(
        {:scenery_plan, epoch, stamp, plan, config},
        %{scenery_protocol: 1, port: port} = state
      )
      when not is_nil(port) do
    {link, bytes} = Transport.plan(state.scenery, epoch, stamp, plan, config)
    if bytes, do: send_payload(port, bytes)
    {:noreply, %{state | scenery: link}}
  end

  def handle_info(
        {:scenery_tiles, epoch, token, tiles},
        %{scenery_protocol: 1, port: port} = state
      )
      when not is_nil(port) do
    {link, bytes} = Transport.offer(state.scenery, epoch, token, tiles)
    if bytes, do: send_payload(port, bytes)
    {:noreply, %{state | scenery: link}}
  end

  def handle_info({:scenery_plan, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:scenery_tiles, _, _, _}, state), do: {:noreply, state}

  def handle_info({:scenery_error, reason}, state) do
    Logger.warning("Scenery view rejected: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({ref, chunks}, state) when is_reference(ref) and is_list(chunks) do
    {loader, accepted} = ChunkLoader.complete(state.loader, ref, chunks)

    send_chunks(state, accepted)
    sent = Enum.reduce(accepted, state.sent, fn {key, _}, acc -> MapSet.put(acc, key) end)
    {:noreply, %{state | sent: sent, loader: ChunkLoader.dispatch(loader)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.loader.tasks, ref),
      do: {:stop, {:chunk_request_failed, reason}, state},
      else: {:noreply, state}
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
    Scenery.disconnect(Scenery, self())
    Enum.each(state.exit_waiters, &GenServer.reply(&1, {:ok, status}))
    if loader = Map.get(state, :loader), do: ChunkLoader.cancel(loader)

    {:noreply,
     state
     |> Map.merge(%{
       port: nil,
       sent: MapSet.new(),
       player: nil,
       exit_status: status,
       exit_waiters: []
     })
     |> Map.put(:loader, ChunkLoader.new())
     |> Map.put(:scenery, %Transport{})}
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
    {loader, accepted} = ChunkLoader.publish(state.loader, key, revision)

    if accepted do
      send_chunk(state.port, key, revision, data)
    end

    sent = if accepted, do: MapSet.put(state.sent, key), else: state.sent
    {:noreply, %{state | loader: loader, sent: sent}}
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
    center = center(player)
    next = if state.center != center, do: stream(state, center), else: state
    {:noreply, %{next | player: player}}
  end

  defp handle_packet(%{"type" => "input"} = packet, state) do
    Characters.input(packet)
    state
  end

  defp handle_packet(%{"type" => "capabilities", "chunk_protocol" => 1} = packet, state) do
    protocol = if packet["scenery_protocol"] == 1, do: 1, else: 0
    request_scenery(%{state | chunk_protocol: 1, scenery_protocol: protocol})
  end

  defp handle_packet(
         %{"type" => "scenery_ready", "epoch" => epoch, "delivery" => delivery},
         state
       ) do
    {link, acknowledged} = Transport.credit(state.scenery, epoch, delivery)

    if acknowledged do
      {epoch, token} = acknowledged
      Scenery.acknowledge(Scenery, epoch, token)
    end

    %{state | scenery: link}
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
      center: nil,
      loader: ChunkLoader.new(),
      stream_ref: nil,
      bounds: World.generation().bounds,
      player: nil,
      exit_status: nil,
      exit_waiters: [],
      process_watch: watch,
      chunk_protocol: 0,
      scenery_protocol: 0,
      scenery: %Transport{}
    }
  end

  defp center(player),
    do:
      {Integer.floor_div(floor(player.x), @chunk_side),
       Integer.floor_div(floor(player.y), @chunk_side),
       Integer.floor_div(floor(player.z), @chunk_side)}

  defp stream(%{port: nil} = state, _), do: state

  defp stream(state, center) do
    keys = ChunkStream.keys(center, state.bounds, @radius)
    wanted = MapSet.new(keys)

    Enum.each(MapSet.difference(state.sent, wanted), fn key ->
      send_packet(state.port, %{type: "forget", key: Tuple.to_list(key)})
    end)

    ref = make_ref()
    send(self(), {:stream_batch, ref})

    next = %{
      state
      | center: center,
        sent: MapSet.intersection(state.sent, wanted),
        loader: ChunkLoader.reset(state.loader, keys),
        stream_ref: ref
    }

    request_scenery(next)
  end

  defp request_scenery(%{port: port, scenery_protocol: 1, center: {x, y, z}} = state)
       when not is_nil(port) do
    Scenery.view(Scenery, self(), {x * 16 + 8, y * 16 + 8, z * 16 + 8})
    state
  end

  defp request_scenery(state), do: state

  defp send_chunk(port, key, revision, data) do
    send_packet(port, %{
      type: "chunk",
      key: Tuple.to_list(key),
      revision: revision,
      data: Base.encode64(data)
    })
  end

  defp send_chunks(_state, []), do: :ok

  defp send_chunks(%{chunk_protocol: 1} = state, chunks),
    do: send_payload(state.port, ChunkWire.encode(chunks))

  defp send_chunks(state, chunks) do
    chunks =
      Enum.map(chunks, fn {key, chunk} ->
        %{key: Tuple.to_list(key), revision: chunk.revision, data: Base.encode64(chunk.data)}
      end)

    send_packet(state.port, %{type: "chunks", chunks: chunks})
  end

  @impl true
  def terminate(_reason, state) do
    if loader = Map.get(state, :loader), do: ChunkLoader.cancel(loader)
    :ok
  end

  defp send_packet(nil, _packet), do: :ok

  defp send_packet(port, packet) do
    send_payload(port, Jason.encode!(packet))
  end

  defp send_payload(nil, _), do: :ok

  defp send_payload(port, bytes) do
    Port.command(port, bytes)
  rescue
    ArgumentError -> {:error, :client_closed}
  end
end
