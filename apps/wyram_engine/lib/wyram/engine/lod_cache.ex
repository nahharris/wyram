defmodule Wyram.Engine.LodCache do
  @moduledoc "Pure byte-accounted LRU for revision-stamped encoded LOD tiles."

  @default_limit 256 * 1024 * 1024
  @sizes [2, 4, 8, 16]

  defstruct limit: @default_limit, bytes: 0, clock: 0, entries: %{}

  @type tile_key :: {2 | 4 | 8 | 16, integer(), integer(), integer()}
  @type cache_key :: {tile_key(), non_neg_integer()}

  @spec new(non_neg_integer()) :: %__MODULE__{}
  def new(limit \\ @default_limit) do
    unless is_integer(limit) and limit >= 0,
      do: raise(ArgumentError, "LOD cache byte limit must be a nonnegative integer")

    %__MODULE__{limit: limit}
  end

  @spec get(%__MODULE__{}, cache_key()) ::
          {%__MODULE__{}, {:ok, binary()} | :miss}
  def get(%__MODULE__{} = cache, key) do
    validate_cache_key!(key)

    case Map.fetch(cache.entries, key) do
      :error ->
        {cache, :miss}

      {:ok, entry} ->
        clock = cache.clock + 1
        entry = %{entry | used: clock}
        {%{cache | clock: clock, entries: Map.put(cache.entries, key, entry)}, {:ok, entry.data}}
    end
  end

  @spec put(%__MODULE__{}, cache_key(), binary()) ::
          {%__MODULE__{}, :ok | {:error, :oversized}}
  def put(%__MODULE__{} = cache, key, data) when is_binary(data) do
    validate_cache_key!(key)
    size = byte_size(data)

    if size > cache.limit do
      {cache, {:error, :oversized}}
    else
      cache = remove_entry(cache, key)
      cache = evict_until_fits(cache, size)
      clock = cache.clock + 1
      entry = %{data: data, bytes: size, used: clock}

      {%{
         cache
         | clock: clock,
           bytes: cache.bytes + size,
           entries: Map.put(cache.entries, key, entry)
       }, :ok}
    end
  end

  @spec invalidate(%__MODULE__{}, [tile_key()]) :: %__MODULE__{}
  def invalidate(%__MODULE__{} = cache, tile_keys) when is_list(tile_keys) do
    Enum.each(tile_keys, &validate_tile_key!/1)
    tile_set = MapSet.new(tile_keys)

    Enum.reduce(cache.entries, cache, fn {{tile, _revision} = key, _entry}, acc ->
      if MapSet.member?(tile_set, tile), do: remove_entry(acc, key), else: acc
    end)
  end

  defp remove_entry(cache, key) do
    case Map.pop(cache.entries, key) do
      {nil, _entries} ->
        cache

      {entry, entries} ->
        %{cache | entries: entries, bytes: cache.bytes - entry.bytes}
    end
  end

  defp evict_until_fits(cache, size) when cache.bytes + size <= cache.limit, do: cache

  defp evict_until_fits(cache, size) do
    {key, _entry} = Enum.min_by(cache.entries, fn {key, entry} -> {entry.used, key} end)
    cache |> remove_entry(key) |> evict_until_fits(size)
  end

  defp validate_cache_key!({tile, revision}) do
    validate_tile_key!(tile)

    unless is_integer(revision) and revision >= 0,
      do: raise(ArgumentError, "LOD cache revision must be a nonnegative integer")
  end

  defp validate_cache_key!(_),
    do: raise(ArgumentError, "LOD cache key must contain a tile key and revision")

  defp validate_tile_key!({size, x, y, z}) do
    unless size in @sizes and Enum.all?([x, y, z], &is_integer/1),
      do: raise(ArgumentError, "LOD cache tile key is invalid")
  end

  defp validate_tile_key!(_), do: raise(ArgumentError, "LOD cache tile key is invalid")
end
