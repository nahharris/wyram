defmodule Wyram.Engine.World do
  @moduledoc "Routes chunk operations to region actors and durably records edits."
  use GenServer

  alias Wyram.Engine.{Native, PluginManager, Region, WorldGenerator}

  @region_side 4
  @chunk_side 16
  @coordinate_limit 1_000_000
  @air_chunk %{data: :binary.copy(<<0>>, 8192), revision: 0}

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec get_chunk(integer(), integer(), integer()) ::
          %{data: binary(), revision: non_neg_integer()}
  def get_chunk(cx, cy, cz) do
    if supported_key?({cx, cy, cz}),
      do: GenServer.call(region_pid(cx, cz), {:chunk, {cx, cy, cz}}),
      else: @air_chunk
  end

  def generation, do: GenServer.call(__MODULE__, :generation)

  def surface_definitions(definitions) do
    case generation() do
      %{resource: nil} -> definitions
      %{resource: resource} -> place_definitions(resource, definitions)
    end
  end

  defp place_definitions(resource, definitions) do
    {sx, _, sz} = Native.generator_spawn(resource)

    positions =
      Enum.map(definitions, fn definition ->
        {x, _, z} = definition.position
        {x + sx, z + sz}
      end)

    samples =
      Enum.flat_map(positions, fn {x, z} ->
        for dx <- [-0.5, 0.5], dz <- [-0.5, 0.5], do: {floor(x + dx), floor(z + dz)}
      end)

    {:ok, heights} = Native.surface_heights(resource, samples)

    definitions
    |> Enum.zip(positions)
    |> Enum.zip(Enum.chunk_every(heights, 4))
    |> Enum.map(fn {{definition, {x, z}}, samples} ->
      %{definition | position: {x, Enum.max(samples) + 0.05, z}}
    end)
  end

  @spec get_chunks([{integer(), integer(), integer()}]) :: [
          {{integer(), integer(), integer()}, binary()}
        ]
  def get_chunks(keys) do
    Enum.map(get_chunk_snapshots(keys), fn {key, chunk} -> {key, chunk.data} end)
  end

  def get_chunk_snapshots(keys) do
    {supported, outside} = keys |> Enum.uniq() |> Enum.split_with(&supported_key?/1)

    chunks =
      supported
      |> Enum.group_by(fn {cx, _cy, cz} -> region_pid(cx, cz) end)
      |> Enum.flat_map(fn {pid, owned} -> GenServer.call(pid, {:chunk_snapshots, owned}) end)

    chunks ++ Enum.map(outside, &{&1, @air_chunk})
  end

  @spec get_block(integer(), integer(), integer()) :: non_neg_integer()
  def get_block(x, y, z) do
    if supported_position?({x, y, z}) do
      {key, local} = address({x, y, z})
      GenServer.call(region_pid(elem(key, 0), elem(key, 2)), {:block, key, local})
    else
      0
    end
  end

  @spec set_block(integer(), integer(), integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def set_block(x, y, z, id) do
    %{bounds: {low, high}} = generation()

    if supported_position?({x, y, z}) and y in low..high do
      {key, local} = address({x, y, z})
      GenServer.call(region_pid(elem(key, 0), elem(key, 2)), {:set, key, local, id})
    else
      {:error, :out_of_world}
    end
  end

  def get_blocks(positions) do
    {supported, outside} = positions |> Enum.uniq() |> Enum.split_with(&supported_position?/1)

    values =
      supported
      |> group_positions()
      |> Enum.flat_map(fn {pid, entries} -> GenServer.call(pid, {:read_blocks, entries}) end)

    Map.new(values ++ Enum.map(outside, &{&1, 0}))
  end

  def schedule_liquids(positions, due) do
    %{bounds: {low, high}} = generation()

    positions =
      Enum.filter(positions, fn {_, y, _} = position ->
        supported_position?(position) and y in low..high
      end)

    Enum.each(group_positions(positions), fn {pid, entries} ->
      GenServer.cast(pid, {:schedule_liquids, entries, due})
    end)
  end

  def apply_liquid_edits(edits) do
    %{bounds: {low, high}} = generation()

    edits
    |> Enum.filter(fn {{_, y, _} = position, _, _} ->
      supported_position?(position) and y in low..high
    end)
    |> Enum.group_by(fn {{x, _, z}, _, _} ->
      region_pid(Integer.floor_div(x, 16), Integer.floor_div(z, 16))
    end)
    |> Enum.each(fn {pid, owned} ->
      entries =
        Enum.map(owned, fn {position, expected, id} ->
          {key, local} = address(position)
          {position, key, local, expected, id}
        end)

      GenServer.call(pid, {:liquid_edits, entries})
    end)
  end

  defp supported_position?(position),
    do:
      position |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and abs(&1) <= @coordinate_limit))

  defp supported_key?(key),
    do:
      key
      |> Tuple.to_list()
      |> Enum.all?(&(is_integer(&1) and abs(&1) <= div(@coordinate_limit, @chunk_side)))

  defp group_positions(positions) do
    positions
    |> Enum.map(fn position ->
      {key, local} = address(position)
      {position, key, local}
    end)
    |> Enum.group_by(fn {_, {cx, _, cz}, _} -> region_pid(cx, cz) end)
  end

  @spec region_pid(integer(), integer()) :: pid()
  def region_pid(cx, cz) do
    region = {Integer.floor_div(cx, @region_side), Integer.floor_div(cz, @region_side)}

    case Registry.lookup(Wyram.Engine.RegionRegistry, region) do
      [{pid, _}] -> if(Process.alive?(pid), do: pid, else: start_region(region))
      [] -> start_region(region)
    end
  end

  @spec saved_chunks({integer(), integer()}) :: map()
  def saved_chunks(region), do: GenServer.call(__MODULE__, {:saved_chunks, region})

  @spec persist_edit({integer(), integer(), integer()}, map()) :: :ok | {:error, atom()}
  def persist_edit(key, chunk), do: GenServer.call(__MODULE__, {:persist_edit, key, chunk})

  @impl true
  def init(options) do
    directory = Keyword.fetch!(options, :directory)
    path = Path.join(directory, "world.json")
    versions = PluginManager.plugin_versions()

    config = PluginManager.worldgen()
    identity = WorldGenerator.identity(config)
    default_seed = if config, do: config.seed, else: 2026

    with {:ok, saved} <- load_or_create(path, versions, identity, default_seed),
         {:ok, generation} <-
           WorldGenerator.compile(
             config,
             saved.seed,
             PluginManager.terrain_palette(),
             PluginManager.blocks()
           ) do
      {:ok, Map.merge(saved, %{path: path, generation: generation})}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}

  def handle_call({:saved_chunks, {rx, rz}}, _from, state) do
    chunks =
      Map.filter(state.edited, fn {{cx, _cy, cz}, _} ->
        Integer.floor_div(cx, @region_side) == rx and
          Integer.floor_div(cz, @region_side) == rz
      end)

    {:reply, chunks, state}
  end

  def handle_call({:persist_edit, key, chunk}, _from, state) do
    next = put_in(state.edited[key], chunk)

    case persist(next) do
      :ok -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_region(region) do
    case DynamicSupervisor.start_child(Wyram.Engine.RegionSupervisor, {Region, region}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "could not start region #{inspect(region)}: #{inspect(reason)}"
    end
  end

  defp address({x, y, z}) do
    {{Integer.floor_div(x, @chunk_side), Integer.floor_div(y, @chunk_side),
      Integer.floor_div(z, @chunk_side)},
     {Integer.mod(x, @chunk_side), Integer.mod(y, @chunk_side), Integer.mod(z, @chunk_side)}}
  end

  defp load_or_create(path, versions, identity, seed) do
    case load_world(path, versions, identity) do
      {:error, :enoent} -> {:ok, %{edited: %{}, seed: seed, plugins: versions}}
      result -> result
    end
  end

  defp load_world(path, versions, identity) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- compatible_plugins?(data["plugins"], versions),
         true <- compatible_generator?(data, identity),
         true <- is_integer(data["seed"]) and data["seed"] in 0..18_446_744_073_709_551_615,
         {:ok, chunks} <- decode_chunks(data["chunks"] || %{}) do
      {:ok, %{seed: data["seed"], plugins: versions, edited: chunks}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :incompatible_save}
      _ -> {:error, :invalid_save}
    end
  end

  defp compatible_generator?(%{"format" => 1}, "legacy-v1"), do: true
  defp compatible_generator?(%{"format" => 2, "generator" => identity}, identity), do: true
  defp compatible_generator?(_, _), do: false

  defp compatible_plugins?(saved, active) when is_map(saved) do
    Enum.all?(saved, fn {id, version} -> active[id] == version end)
  end

  defp compatible_plugins?(_, _), do: false

  defp decode_chunks(chunks) when is_map(chunks) do
    Enum.reduce_while(chunks, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      with [cx, cy, cz] <- String.split(name, ",") |> Enum.map(&Integer.parse/1),
           {{x, ""}, {y, ""}, {z, ""}} <- {cx, cy, cz},
           {:ok, bytes} <- Base.decode64(value["data"]),
           true <- byte_size(bytes) == 8192 do
        {:cont, {:ok, Map.put(acc, {x, y, z}, %{data: bytes, revision: value["revision"]})}}
      else
        _ -> {:halt, {:error, :invalid_save}}
      end
    end)
  end

  defp decode_chunks(_), do: {:error, :invalid_save}

  defp persist(state) do
    payload = %{
      format: 2,
      generator: state.generation.identity,
      seed: state.seed,
      plugins: state.plugins,
      blocks: PluginManager.blocks(),
      chunks:
        Map.new(state.edited, fn {{cx, cy, cz}, chunk} ->
          {"#{cx},#{cy},#{cz}", %{revision: chunk.revision, data: Base.encode64(chunk.data)}}
        end)
    }

    temp = state.path <> ".tmp"

    with :ok <- File.write(temp, Jason.encode!(payload)) do
      File.rename(temp, state.path)
    end
  end
end
