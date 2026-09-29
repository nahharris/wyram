defmodule Wyram.Engine.Region do
  @moduledoc "Owns dense chunk binaries for one 4 by 4 chunk-column region."
  use GenServer

  alias Wyram.Engine.{ClientPort, Native, PluginManager, World}

  def start_link(region) do
    GenServer.start_link(__MODULE__, region,
      name: {:via, Registry, {Wyram.Engine.RegionRegistry, region}}
    )
  end

  @impl true
  def init(region), do: {:ok, %{region: region, chunks: World.saved_chunks(region)}}

  @impl true
  def handle_call({:chunk, key}, _from, state) do
    {chunk, state} = ensure_chunk(state, key)
    {:reply, chunk, state}
  end

  def handle_call({:block, key, local}, _from, state) do
    {chunk, state} = ensure_chunk(state, key)
    {:ok, id} = apply(Native, :read_block, [chunk.data | Tuple.to_list(local)])
    {:reply, id, state}
  end

  def handle_call({:set, key, local, id}, _from, state) do
    if Map.has_key?(PluginManager.block_colors(), id) or id == 0 do
      edit_block(state, key, local, id)
    else
      {:reply, {:error, :unknown_block}, state}
    end
  end

  defp edit_block(state, key, local, id) do
    {chunk, state} = ensure_chunk(state, key)

    case apply(Native, :write_block, [chunk.data | Tuple.to_list(local)] ++ [id]) do
      {:ok, data} -> commit_edit(state, key, chunk.revision + 1, data)
      {:error, _} -> {:reply, {:error, :invalid_block}, state}
    end
  end

  defp commit_edit(state, key, revision, data) do
    changed = %{data: data, revision: revision}

    case World.persist_edit(key, changed) do
      :ok ->
        ClientPort.publish_chunk(key, revision, data)
        {:reply, {:ok, revision}, put_in(state.chunks[key], changed)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_chunk(state, key) do
    case state.chunks do
      %{^key => chunk} ->
        {chunk, state}

      _ ->
        [cx, cy, cz] = Tuple.to_list(key)

        data =
          apply(
            Native,
            :generate_chunk,
            [2026, cx, cy, cz] ++ PluginManager.terrain_palette()
          )

        chunk = %{data: data, revision: 0}
        {chunk, put_in(state.chunks[key], chunk)}
    end
  end
end
