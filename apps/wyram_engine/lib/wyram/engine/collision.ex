defmodule Wyram.Engine.Collision do
  @moduledoc "One packed collision query batch over immutable region-owned chunk snapshots."
  alias Wyram.Character.State
  alias Wyram.Engine.{Native, PluginManager, World}

  @spec sweep([State.query()]) :: {:ok, [State.result()]} | {:error, term()}
  def sweep(queries) do
    keys = queries |> Enum.flat_map(&chunk_keys/1) |> Enum.uniq()

    if length(keys) <= 4096 and length(queries) <= 256 do
      Native.sweep_bodies(World.get_chunks(keys), queries, PluginManager.noncolliding())
    else
      {:error, :oversized_character_batch}
    end
  catch
    :exit, _ -> {:error, :terrain_unavailable}
  end

  defp chunk_keys({position, delta, radius, height}) do
    p = Tuple.to_list(position)
    d = Tuple.to_list(delta)
    lower = [-radius, 0.0, -radius]
    upper = [radius, height, radius]

    ranges =
      Enum.zip([p, d, lower, upper])
      |> Enum.map(fn {at, change, low, high} ->
        first = floor((min(at, at + change) + low) / 16)
        last = floor((max(at, at + change) + high) / 16)
        first..last
      end)

    [xs, ys, zs] = ranges
    for x <- xs, y <- ys, z <- zs, do: {x, y, z}
  end
end
