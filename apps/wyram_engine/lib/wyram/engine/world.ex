defmodule Wyram.Engine.World do
  @moduledoc "Authoritative voxel chunks and revisioned edits."
  use GenServer
  alias Wyram.Engine.{ClientPort, Native, PluginManager}

  @seed 2026
  @chunk_side 16

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec get_chunk(integer(), integer(), integer()) :: %{
          data: binary(),
          revision: non_neg_integer()
        }
  def get_chunk(cx, cy, cz), do: GenServer.call(__MODULE__, {:chunk, {cx, cy, cz}})

  @spec get_block(integer(), integer(), integer()) :: non_neg_integer()
  def get_block(x, y, z), do: GenServer.call(__MODULE__, {:block, {x, y, z}})

  @spec set_block(integer(), integer(), integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def set_block(x, y, z, id), do: GenServer.call(__MODULE__, {:set, {x, y, z}, id})

  @impl true
  def init(options) do
    directory = Keyword.fetch!(options, :directory)
    path = Path.join(directory, "world.json")
    versions = PluginManager.plugin_versions()

    case load_world(path, versions) do
      {:ok, saved} ->
        {:ok, Map.merge(%{path: path, chunks: %{}, edited: %{}, seed: @seed}, saved)}

      {:error, :enoent} ->
        {:ok, %{path: path, chunks: %{}, edited: %{}, seed: @seed, plugins: versions}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:chunk, key}, _from, state) do
    {chunk, state} = ensure_chunk(state, key)
    {:reply, chunk, state}
  end

  def handle_call({:block, point}, _from, state) do
    {key, local} = address(point)
    {chunk, state} = ensure_chunk(state, key)
    {:ok, id} = apply(Native, :read_block, [chunk.data | Tuple.to_list(local)])
    {:reply, id, state}
  end

  def handle_call({:set, point, id}, _from, state) do
    if Map.has_key?(PluginManager.block_colors(), id) or id == 0 do
      edit_block(state, point, id)
    else
      {:reply, {:error, :unknown_block}, state}
    end
  end

  defp edit_block(state, point, id) do
    {key, local} = address(point)
    {chunk, state} = ensure_chunk(state, key)

    case apply(Native, :write_block, [chunk.data | Tuple.to_list(local)] ++ [id]) do
      {:ok, data} -> save_edit(state, key, chunk.revision + 1, data)
      {:error, _} -> {:reply, {:error, :invalid_block}, state}
    end
  end

  defp save_edit(state, key, revision, data) do
    changed = %{data: data, revision: revision}
    next = state |> put_in([:chunks, key], changed) |> put_in([:edited, key], changed)

    case persist(next) do
      :ok ->
        ClientPort.publish_chunk(key, revision, data)
        {:reply, {:ok, revision}, next}

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
            [state.seed, cx, cy, cz] ++ PluginManager.terrain_palette()
          )

        chunk = %{data: data, revision: 0}
        {chunk, put_in(state.chunks[key], chunk)}
    end
  end

  defp address({x, y, z}) do
    {{div_floor(x), div_floor(y), div_floor(z)},
     {Integer.mod(x, @chunk_side), Integer.mod(y, @chunk_side), Integer.mod(z, @chunk_side)}}
  end

  defp div_floor(value), do: Integer.floor_div(value, @chunk_side)

  defp load_world(path, versions) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- data["plugins"] == versions,
         true <- data["format"] == 1,
         {:ok, chunks} <- decode_chunks(data["chunks"] || %{}) do
      {:ok, %{seed: data["seed"], plugins: versions, chunks: chunks, edited: chunks}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :incompatible_save}
      _ -> {:error, :invalid_save}
    end
  end

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
