# Run against immutable engine/NIF snapshots with a fresh real-game plugin.
alias Wyram.Engine.{Native, World, WorldGenerator}
context = World.generation()
{x, y, z} = Native.generator_spawn(context.resource)
{cx, cy, cz} = {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}
{min_y, max_y} = context.bounds

# Keep the historical generation workload independent of renderer residency.
keys =
  for x <- (cx - 4)..(cx + 4),
      z <- (cz - 4)..(cz + 4),
      y <- Integer.floor_div(min_y, 16)..Integer.floor_div(max_y, 16),
      do: {x, y, z}

keys =
  Enum.sort_by(keys, fn {x, y, z} -> {(x - cx) ** 2 + (y - cy) ** 2 + (z - cz) ** 2, y, x, z} end)

{us, chunks} = :timer.tc(fn -> WorldGenerator.chunks(context, keys) end)
true = length(chunks) == 2592

digest =
  chunks
  |> Enum.sort()
  |> :erlang.term_to_binary()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16()

empty = Enum.count(chunks, fn {_, bytes} -> bytes == :binary.copy(<<0>>, 8192) end)
nif_path = Path.join(to_string(:code.priv_dir(:wyram_engine)), "native/wyram_nif.dll")
nif_hash = File.read!(nif_path) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16()

result = %{
  schema: 1,
  ms: us / 1000,
  digest: digest,
  chunks: length(chunks),
  empty: empty,
  nif_sha256: nif_hash
}

File.write!(System.fetch_env!("WYRAM_FLIGHT_PHASES"), Jason.encode!(result))
IO.inspect(result)
:ok = Application.stop(:wyram_engine)
