defmodule Wyram.Engine.Scenery.CachedGeneration do
  @moduledoc false
  alias Wyram.Engine.Native
  alias Wyram.Engine.Scenery.{Identity, Store}
  alias Wyram.Scenery.Key

  def run(%{cache: cache, cache_identity: identity}, resource, inputs)
      when not is_nil(cache) and is_binary(identity) and byte_size(identity) == 32 do
    requests =
      Enum.map(inputs, fn {{position, level}, samples} ->
        key = %Key{position: position, level: level}
        {Identity.tile(identity, key, samples), key}
      end)

    hits = Store.get(cache, requests)

    misses =
      Enum.zip(inputs, hits) |> Enum.reject(fn {_, hit} -> hit end) |> Enum.map(&elem(&1, 0))

    case generate(resource, misses) do
      {:ok, fresh} ->
        entries =
          Enum.zip(requests, hits)
          |> Enum.reject(fn {_, hit} -> hit end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.zip(fresh)
          |> Enum.map(fn {{tag, key}, bytes} -> {tag, key, bytes} end)

        Store.put(cache, entries)

        {values, []} =
          Enum.map_reduce(hits, fresh, fn
            nil, [bytes | rest] -> {bytes, rest}
            bytes, rest -> {bytes, rest}
          end)

        {:ok, values}

      error ->
        error
    end
  end

  def run(_, resource, inputs), do: generate(resource, inputs)
  defp generate(_, []), do: {:ok, []}
  defp generate(resource, inputs), do: Native.generate_edited_scenic_tiles(resource, inputs)
end
