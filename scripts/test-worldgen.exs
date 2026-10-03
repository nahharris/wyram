alias Wyram.Engine.{Characters, Native, PluginManager, World}

config = PluginManager.worldgen()
true = config.height == 512
true = config.sea_level == 0
context = World.generation()
flow = Enum.at(PluginManager.liquids()[PluginManager.blocks()["wyram:water"]].variants, 1)
:ok = World.apply_liquid_edits([{{8000, 320, 8000}, 0, flow}, {{8000, -193, 8000}, 0, flow}])
true = World.get_block(8000, 320, 8000) == 0
true = World.get_block(8000, -193, 8000) == 0
true = context.bounds == {-192, 319}

{:ok, columns} =
  Native.sample_world(
    context.resource,
    for(z <- -2048..2048//128, x <- -2048..2048//128, do: {x, z})
  )

true = Enum.any?(columns, &(&1.height < -16))
true = Enum.any?(columns, &(&1.height > 64))
true = Enum.any?(columns, & &1.island)
{:error, :out_of_world} = World.set_block(0, -193, 0, 0)
{:error, :out_of_world} = World.set_block(0, 320, 0, 0)

player = Characters.snapshot()

{:ok, [{_, {false, false, false}, false}]} =
  Wyram.Engine.Collision.sweep([
    {List.to_tuple(player.feet), {0.0, 0.0, 0.0}, player.radius, player.height}
  ])

# Edited saves retain the exact generation identity and consume their saved seed.
{:ok, saved} = World.init(directory: Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "worlds"))
true = saved.generation.identity == context.identity
source = Jason.decode!(File.read!(saved.path))
true = source["format"] == 2
true = source["generator"] == context.identity
probe = Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "generator-save-probe")
File.mkdir_p!(probe)
path = Path.join(probe, "world.json")
File.write!(path, Jason.encode!(Map.put(source, "generator", "different")))
{:stop, :incompatible_save} = World.init(directory: probe)
File.write!(path, Jason.encode!(Map.put(source, "seed", 41)))
{:ok, alternate} = World.init(directory: probe)
true = alternate.seed == 41
{:ok, [one]} = Native.sample_world(context.resource, [{1024, 1024}])
{:ok, [two]} = Native.sample_world(alternate.generation.resource, [{1024, 1024}])
false = one.climate == two.climate

IO.puts(
  "512-block world, negative depth, climate fields, islands, safe spawn and save identity smoke passed"
)
