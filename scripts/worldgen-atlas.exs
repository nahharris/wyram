alias Wyram.Engine.{Characters, ChunkStream, Native, World}

context = World.generation()
if is_nil(context.resource), do: raise("the selected game has no configured world generator")
side = 256
step = 32
positions = for z <- 0..(side - 1), x <- 0..(side - 1), do: {x * step - 4096, z * step - 4096}

{sample_us, columns} =
  :timer.tc(fn ->
    positions
    |> Enum.chunk_every(4096)
    |> Enum.flat_map(fn batch ->
      {:ok, values} = Native.sample_world(context.resource, batch)
      values
    end)
  end)

player = Characters.snapshot()

center =
  {Integer.floor_div(floor(player.x), 16), Integer.floor_div(floor(player.y), 16),
   Integer.floor_div(floor(player.z), 16)}

keys = ChunkStream.keys(center, context.bounds, 2)

{generate_us, _} =
  :timer.tc(fn -> keys |> Enum.chunk_every(16) |> Enum.each(&World.get_chunk_snapshots/1) end)

output = List.first(System.argv()) || ".tools/worldgen-atlas.json"
File.mkdir_p!(Path.dirname(output))

File.write!(
  output,
  Jason.encode!(%{
    seed: context.seed,
    bounds: Tuple.to_list(context.bounds),
    sea_level: Wyram.Engine.PluginManager.worldgen().sea_level,
    side: side,
    step: step,
    origin: -4096,
    columns:
      Enum.map(columns, fn column ->
        Map.update!(column, :island, fn island ->
          if island, do: Tuple.to_list(island), else: nil
        end)
      end),
    spawn: [player.x, player.y, player.z],
    sample_ms: sample_us / 1000,
    stream_generation_ms: generate_us / 1000,
    stream_chunks: length(keys)
  })
)

IO.puts(
  "Atlas: #{output}; #{length(keys)} packed chunks in #{generate_us / 1000} ms (current build, no renderer)"
)
