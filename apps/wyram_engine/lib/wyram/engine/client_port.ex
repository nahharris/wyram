defmodule Wyram.Engine.ClientPort do
  @moduledoc "Bounded binary transport to the native graphics client."
  use GenServer
  require Logger

  alias Wyram.Engine.{
    Characters,
    ChunkLoader,
    ChunkStream,
    ChunkWire,
    LodStreamer,
    Native,
    Paths,
    PluginManager,
    World
  }

  @chunk_side 16

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec publish_chunk({integer(), integer(), integer()}, non_neg_integer(), binary()) :: :ok
  def publish_chunk(key, revision, data) do
    GenServer.cast(__MODULE__, {:publish_chunk, key, revision, data})
  end

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def publish_lod(payload), do: GenServer.cast(__MODULE__, {:publish_lod, payload})

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
      descriptors: PluginManager.render_descriptors(),
      noncolliding: PluginManager.noncolliding(),
      placeable: PluginManager.placeable() |> Enum.sort() |> Enum.map(&elem(&1, 1)),
      characters: Characters.latest(),
      models: PluginManager.character_models()
    })

    Characters.connect()
    player = Enum.find(Characters.latest(), &(&1.id == "player"))
    {:noreply, stream(%{state | player: player}, center(player))}
  end

  def handle_info({:stream_batch, ref}, %{stream_ref: ref, port: port} = state)
      when not is_nil(port) do
    loader = ChunkLoader.dispatch(state.loader)
    LodStreamer.near_busy(near_busy?(loader))
    {:noreply, %{state | loader: loader}}
  end

  def handle_info({:stream_batch, _}, state), do: {:noreply, state}

  def handle_info({ref, chunks}, state) when is_reference(ref) and is_list(chunks) do
    {loader, accepted} = ChunkLoader.complete(state.loader, ref, chunks)

    send_chunks(state, accepted)
    sent = Enum.reduce(accepted, state.sent, fn {key, _}, acc -> MapSet.put(acc, key) end)
    loader = ChunkLoader.dispatch(loader)
    LodStreamer.near_busy(near_busy?(loader))
    {:noreply, %{state | sent: sent, loader: loader}}
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
     |> Map.put(:loader, ChunkLoader.new())}
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
  def handle_cast({:publish_lod, payload}, state) do
    if is_binary(payload),
      do: send_payload(state.port, payload),
      else: send_packet(state.port, payload)

    next =
      case payload do
        %{type: "lod_config", enabled: true} ->
          state = %{state | prefetch_radius: state.view_radius + 2}
          if state.center, do: stream(state, state.center), else: state

        _ ->
          state
      end

    {:noreply, next}
  end

  def handle_cast({:publish_chunk, key, revision, data}, state) do
    {loader, accepted} = ChunkLoader.publish(state.loader, key, revision)

    if accepted do
      send_chunk(state.port, key, revision, data)
    end

    sent = if accepted, do: MapSet.put(state.sent, key), else: state.sent
    LodStreamer.invalidate(key)
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
    changed = state.center != center or (state.player && state.player.epoch != player.epoch)
    next = if changed, do: stream(%{state | player: player}, center), else: state
    {:noreply, %{next | player: player}}
  end

  defp handle_packet(%{"type" => "input"} = packet, state) do
    Characters.input(packet)
    state
  end

  defp handle_packet(%{"type" => "capabilities"} = packet, state) do
    chunk_protocol = if packet["chunk_protocol"] == 1, do: 1, else: 0
    forget_protocol = if packet["forget_protocol"] == 1, do: 1, else: 0
    state = %{state | chunk_protocol: chunk_protocol, forget_protocol: forget_protocol}

    if packet["lod_protocol"] == 1 do
      LodStreamer.configure(packet["available_parallelism"])
      %{state | lod_protocol: 1}
    else
      state
    end
  end

  defp handle_packet(%{"type" => "lod_ack", "epoch" => epoch, "tiles" => tiles}, state)
       when is_integer(epoch) and epoch >= 0 and is_list(tiles) and length(tiles) <= 16 do
    Enum.each(tiles, &acknowledge_lod_tile(epoch, &1))

    state
  end

  defp handle_packet(%{"type" => "lod_need", "epoch" => epoch, "keys" => keys}, state)
       when is_integer(epoch) and epoch >= 0 and is_list(keys) and length(keys) <= 16 do
    keys =
      Enum.flat_map(keys, fn
        [size, x, y, z]
        when size in [2, 4, 8, 16] and is_integer(x) and is_integer(y) and is_integer(z) ->
          [{size, x, y, z}]

        _ ->
          []
      end)

    LodStreamer.request(epoch, keys)
    state
  end

  defp handle_packet(%{"type" => "edit", "x" => x, "y" => y, "z" => z, "id" => id}, state)
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(id) do
    World.set_block(x, y, z, id)
    state
  end

  defp handle_packet(_, state), do: state

  defp acknowledge_lod_tile(epoch, [size, x, y, z, revision, ready])
       when size in [2, 4, 8, 16] and is_integer(x) and is_integer(y) and is_integer(z) and
              is_integer(revision) and revision >= 0 and is_boolean(ready),
       do: LodStreamer.acknowledge(epoch, {size, x, y, z}, revision, ready)

  defp acknowledge_lod_tile(_, _), do: :ok

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
      view_radius: ChunkStream.view_radius(),
      prefetch_radius: ChunkStream.view_radius(),
      player: nil,
      exit_status: nil,
      exit_waiters: [],
      process_watch: watch,
      chunk_protocol: 0,
      forget_protocol: 0,
      lod_protocol: 0
    }
  end

  defp center(player),
    do:
      {Integer.floor_div(floor(player.x), @chunk_side),
       Integer.floor_div(floor(player.y), @chunk_side),
       Integer.floor_div(floor(player.z), @chunk_side)}

  defp stream(%{port: nil} = state, _), do: state

  defp stream(state, center) do
    keys = ChunkStream.keys(center, state.bounds, state.prefetch_radius)

    keys =
      if state.prefetch_radius > state.view_radius,
        do: ChunkStream.column_order(keys, center),
        else: keys

    wanted = MapSet.new(keys)

    state.sent
    |> MapSet.difference(wanted)
    |> Enum.to_list()
    |> ChunkStream.forget_packets(state.forget_protocol)
    |> Enum.each(&send_packet(state.port, &1))

    ref = make_ref()
    send(self(), {:stream_batch, ref})

    next = %{
      state
      | center: center,
        sent: MapSet.intersection(state.sent, wanted),
        loader: ChunkLoader.reset(state.loader, keys),
        stream_ref: ref
    }

    LodStreamer.view(center, state.player.epoch, near_busy?(next.loader))
    next
  end

  defp near_busy?(loader), do: loader.pending != [] or map_size(loader.tasks) != 0

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
