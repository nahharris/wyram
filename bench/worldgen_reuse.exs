# Run against immutable engine/NIF snapshots with a fresh real-game plugin.
alias Wyram.Engine.{ChunkStream, Native, World, WorldGenerator}
context = World.generation()
{x, y, z} = Native.generator_spawn(context.resource)
center = {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}
keys = ChunkStream.keys(center, context.bounds, 4)
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
