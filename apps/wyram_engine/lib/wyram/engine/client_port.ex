defmodule Wyram.Engine.ClientPort do
  @moduledoc "Bounded binary transport to the native graphics client."
  use GenServer
  require Logger
  alias Wyram.Engine.{Paths, PluginManager, World}

  @radius 2
  @chunk_side 16

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec publish_chunk({integer(), integer(), integer()}, non_neg_integer(), binary()) :: :ok
  def publish_chunk(key, revision, data) do
    GenServer.cast(__MODULE__, {:publish_chunk, key, revision, data})
  end

  @impl true
  def init(_) do
    executable = Paths.client_executable()

    if File.regular?(executable) do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          {:packet, 4},
          :hide
        ])

      state = %{port: port, sent: MapSet.new(), center: {0, 0}}
      send(self(), :initialize)
      {:ok, state}
    else
      Logger.warning("Native client unavailable at #{executable}; engine running headlessly")
      {:ok, %{port: nil, sent: MapSet.new(), center: {0, 0}}}
    end
  end

  @impl true
  def handle_info(:initialize, state) do
    send_packet(state.port, %{
      type: "hello",
      blocks: PluginManager.blocks(),
      colors: PluginManager.block_colors()
    })

    {:noreply, stream(state, {0, 0})}
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case Jason.decode(bytes) do
      {:ok, %{"type" => "view", "x" => x, "z" => z}} when is_number(x) and is_number(z) ->
        {:noreply,
         stream(
           state,
           {Integer.floor_div(trunc(x), @chunk_side), Integer.floor_div(trunc(z), @chunk_side)}
         )}

      {:ok, %{"type" => "edit", "x" => x, "y" => y, "z" => z, "id" => id}}
      when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(id) ->
        World.set_block(x, y, z, id)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Native client exited with status #{status}")
    {:noreply, %{state | port: nil, sent: MapSet.new()}}
  end

  @impl true
  def handle_cast({:publish_chunk, key, revision, data}, state) do
    if MapSet.member?(state.sent, key) do
      send_chunk(state.port, key, revision, data)
    end

    {:noreply, state}
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
