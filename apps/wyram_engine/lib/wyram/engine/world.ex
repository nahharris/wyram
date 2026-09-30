defmodule Wyram.Engine.World do
  @moduledoc "Routes chunk operations to region actors and durably records edits."
  use GenServer

  alias Wyram.Engine.{PluginManager, Region}

  @region_side 4
  @chunk_side 16

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec get_chunk(integer(), integer(), integer()) ::
          %{data: binary(), revision: non_neg_integer()}
  def get_chunk(cx, cy, cz) do
    GenServer.call(region_pid(cx, cz), {:chunk, {cx, cy, cz}})
  end

  @spec get_chunks([{integer(), integer(), integer()}]) :: [
          {{integer(), integer(), integer()}, binary()}
        ]
  def get_chunks(keys) do
    keys
    |> Enum.uniq()
    |> Enum.group_by(fn {cx, _cy, cz} -> region_pid(cx, cz) end)
    |> Enum.flat_map(fn {pid, owned} -> GenServer.call(pid, {:chunks, owned}) end)
  end

  @spec get_block(integer(), integer(), integer()) :: non_neg_integer()
  def get_block(x, y, z) do
    {key, local} = address({x, y, z})
    GenServer.call(region_pid(elem(key, 0), elem(key, 2)), {:block, key, local})
  end

  @spec set_block(integer(), integer(), integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def set_block(x, y, z, id) do
    {key, local} = address({x, y, z})
    GenServer.call(region_pid(elem(key, 0), elem(key, 2)), {:set, key, local, id})
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

    case load_world(path, versions) do
      {:ok, saved} -> {:ok, Map.merge(%{path: path, edited: %{}, seed: 2026}, saved)}
      {:error, :enoent} -> {:ok, %{path: path, edited: %{}, seed: 2026, plugins: versions}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
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

  defp load_world(path, versions) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- compatible_plugins?(data["plugins"], versions),
         true <- data["format"] == 1,
         {:ok, chunks} <- decode_chunks(data["chunks"] || %{}) do
      {:ok, %{seed: data["seed"], plugins: versions, edited: chunks}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :incompatible_save}
      _ -> {:error, :invalid_save}
    end
  end

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
      format: 1,
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
