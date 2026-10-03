defmodule Wyram.Engine.Region do
  @moduledoc "Owns dense chunk binaries for one 4 by 4 chunk-column region."
  use GenServer

  alias Wyram.Engine.{ClientPort, LiquidSimulation, Native, PluginManager, World, WorldGenerator}

  def start_link(region) do
    GenServer.start_link(__MODULE__, region,
      name: {:via, Registry, {Wyram.Engine.RegionRegistry, region}}
    )
  end

  @impl true
  def init(region) do
    state = %{
      region: region,
      chunks: World.saved_chunks(region),
      pending: %{},
      liquids: PluginManager.liquids(),
      placeable: Map.values(PluginManager.placeable()),
      generation: World.generation()
    }

    seed_liquids(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:chunk, key}, _from, state) do
    {chunk, state} = ensure_chunk(state, key)
    {:reply, chunk, state}
  end

  def handle_call({:chunks, keys}, _from, state) do
    state = ensure_chunks(state, keys)
    {:reply, Enum.map(keys, &{&1, state.chunks[&1].data}), state}
  end

  def handle_call({:chunk_snapshots, keys}, _from, state) do
    state = ensure_chunks(state, keys)
    {:reply, Enum.map(keys, &{&1, state.chunks[&1]}), state}
  end

  def handle_call({:block, key, local}, _from, state) do
    {chunk, state} = ensure_chunk(state, key)
    {:ok, id} = apply(Native, :read_block, [chunk.data | Tuple.to_list(local)])
    {:reply, id, state}
  end

  def handle_call({:set, key, local, id}, _from, state) do
    if id in state.placeable or id == 0 do
      edit_block(state, key, local, id)
    else
      {:reply, {:error, :unknown_block}, state}
    end
  end

  def handle_call({:read_blocks, entries}, _from, state) do
    {values, state} =
      entries
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.map_reduce(state, fn {key, entries}, acc ->
        {chunk, acc} = ensure_chunk(acc, key)
        {:ok, ids} = Native.read_blocks(chunk.data, Enum.map(entries, &elem(&1, 2)))
        {Enum.zip(Enum.map(entries, &elem(&1, 0)), ids), acc}
      end)

    {:reply, List.flatten(values), state}
  end

  def handle_call({:liquid_frontier, now, limit}, _from, state) do
    positions =
      state.pending
      |> Enum.filter(fn {_, due} -> due <= now end)
      |> Enum.sort_by(fn {position, due} -> {due, position} end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 0))

    {:reply, positions, %{state | pending: Map.drop(state.pending, positions)}}
  end

  def handle_call({:liquid_edits, entries}, _from, state) do
    state =
      entries
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.reduce(state, fn {key, batch}, acc -> apply_liquid_batch(acc, key, batch) end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:schedule_liquids, entries, due}, state) do
    pending =
      Enum.reduce(entries, state.pending, fn {position, _, _}, acc ->
        # A newer cause postpones reevaluation until its material's flow interval elapses.
        Map.update(acc, position, due, &max(&1, due))
      end)

    {:noreply, %{state | pending: pending}}
  end

  def handle_cast(:seed_liquids, state) do
    seed_liquids(state)
    {:noreply, state}
  end

  defp apply_liquid_batch(state, key, entries) do
    {chunk, state} = ensure_chunk(state, key)
    batch = Enum.map(entries, fn {_, _, {x, y, z}, expected, id} -> {x, y, z, expected, id} end)

    with true <- Enum.all?(entries, &valid_liquid_edit?(&1, state.liquids)),
         {:ok, data} <- Native.compare_write_blocks(chunk.data, batch),
         {:reply, {:ok, _}, next} <- commit_edit(state, key, chunk.revision + 1, data) do
      Enum.each(entries, fn {position, _, _, expected, id} ->
        notify_liquid(position, expected, id, state.liquids)
      end)

      next
    else
      _ ->
        LiquidSimulation.changed(Enum.map(entries, &elem(&1, 0)), 100)
        state
    end
  end

  defp valid_liquid_edit?({_, _, _, expected, id}, table) do
    old = table[expected]
    new = table[id]

    (expected == 0 or (not is_nil(old) and old.level > 0)) and
      (id == 0 or (not is_nil(new) and new.level > 0))
  end

  defp notify_liquid(position, old, id, table) do
    settings = table[id] || table[old]
    delay = if settings, do: settings.flow_ms, else: 100
    LiquidSimulation.changed([position], delay)
  end

  defp seed_liquids(state) do
    Enum.each(state.chunks, fn {key, chunk} -> seed_chunk(key, chunk.data, state.liquids) end)
  end

  defp seed_chunk(_key, _data, table) when map_size(table) == 0, do: :ok

  defp seed_chunk({cx, cy, cz}, data, table) do
    {:ok, positions} = Native.liquid_positions(data, Map.keys(table))
    positions = Enum.map(positions, fn {x, y, z} -> {cx * 16 + x, cy * 16 + y, cz * 16 + z} end)
    if positions != [], do: LiquidSimulation.changed(positions, 100)
  end

  defp edit_block(state, key, local, id) do
    {chunk, state} = ensure_chunk(state, key)

    case apply(Native, :write_block, [chunk.data | Tuple.to_list(local)] ++ [id]) do
      {:ok, data} ->
        {:ok, old} = apply(Native, :read_block, [chunk.data | Tuple.to_list(local)])

        state
        |> commit_edit(key, chunk.revision + 1, data)
        |> notify_edit(key, local, old, id, state.liquids)

      {:error, _} ->
        {:reply, {:error, :invalid_block}, state}
    end
  end

  defp notify_edit({:reply, {:ok, _}, _} = result, {cx, cy, cz}, {x, y, z}, old, id, table) do
    if map_size(table) > 0,
      do: notify_liquid({cx * 16 + x, cy * 16 + y, cz * 16 + z}, old, id, table)

    result
  end

  defp notify_edit(result, _, _, _, _, _), do: result

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
    state = ensure_chunks(state, [key])
    {state.chunks[key], state}
  end

  defp ensure_chunks(state, keys) do
    missing = keys |> Enum.uniq() |> Enum.reject(&Map.has_key?(state.chunks, &1))
    generated = WorldGenerator.chunks(state.generation, missing)

    Enum.reduce(generated, state, fn {key, data}, acc ->
      # Worldgen liquids are stable sources. Edits wake adjacent liquid cells; do not queue entire oceans.
      if is_nil(state.generation.resource), do: seed_chunk(key, data, state.liquids)
      put_in(acc.chunks[key], %{data: data, revision: 0})
    end)
  end
end
