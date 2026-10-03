alias Wyram.Engine.{Native, PluginManager, World}

blocks = PluginManager.placeable()
water = Map.fetch!(blocks, "wyram:water")
lava = Map.fetch!(blocks, "wyram:lava")
stone = Map.fetch!(blocks, "wyram:stone")
liquids = PluginManager.liquids()
true = liquids[water].flow_ms < liquids[lava].flow_ms
true = liquids[water].max_level > liquids[lava].max_level
true = PluginManager.render_descriptors()[water].opacity < 255
true = PluginManager.render_descriptors()[lava].emissive

# A sealed channel crosses both a chunk and a region boundary at x=64.
for x <- 60..67, z <- 499..501 do
  {:ok, _} = World.set_block(x, 79, z, stone)

  for y <- 80..83 do
    wall = z != 500 or x in [60, 67]
    {:ok, _} = World.set_block(x, y, z, if(wall, do: stone, else: 0))
  end
end

wait = fn predicate ->
  Enum.reduce_while(1..120, false, fn _, _ ->
    if predicate.() do
      {:halt, true}
    else
      Process.sleep(100)
      {:cont, false}
    end
  end)
end

{:ok, _} = World.set_block(63, 83, 500, water)

true =
  wait.(fn ->
    cell = World.get_block(64, 80, 500)
    Map.has_key?(liquids, cell) and liquids[cell].source == water
  end)

true = World.get_block(63, 83, 500) == water

# A stale simulation snapshot cannot overwrite a newer solid player edit.
flowing = World.get_block(64, 80, 500)
{:ok, _} = World.set_block(64, 80, 500, stone)
:ok = World.apply_liquid_edits([{{64, 80, 500}, flowing, 0}])
true = World.get_block(64, 80, 500) == stone
{:ok, _} = World.set_block(64, 80, 500, 0)
true = wait.(fn -> Map.has_key?(liquids, World.get_block(64, 80, 500)) end)

# Authoritative collision must agree with the client noncollision descriptor.
query = {{63.5, 80.0, 500.5}, {0.3, 0.0, 0.0}, 0.1, 0.5}

{:ok, [{_, {false, false, false}, false}]} =
  Native.sweep_bodies(
    World.get_chunks([{3, 5, 31}, {4, 5, 31}]),
    [query],
    PluginManager.noncolliding()
  )

right = World.region_pid(4, 31)
:ok = DynamicSupervisor.terminate_child(Wyram.Engine.RegionSupervisor, right)
true = Map.has_key?(liquids, World.get_block(64, 80, 500))
{:ok, _} = World.set_block(63, 83, 500, 0)

true =
  wait.(fn ->
    Enum.all?(for(x <- 61..66, y <- 80..83, do: {x, y}), fn {x, y} ->
      World.get_block(x, y, 500) == 0
    end)
  end)

{:error, :unknown_block} = World.set_block(63, 80, 500, Enum.at(liquids[water].variants, 1))

# Lava uses the same core system, and two unlike sources remain distinct.
{:ok, _} = World.set_block(64, 80, 500, water)
{:ok, _} = World.set_block(65, 80, 500, lava)

true =
  wait.(fn ->
    cell = World.get_block(66, 80, 500)
    Map.has_key?(liquids, cell) and liquids[cell].source == lava
  end)

true = World.get_block(64, 80, 500) == water
true = World.get_block(65, 80, 500) == lava
{:ok, _} = World.set_block(64, 80, 500, 0)
{:ok, _} = World.set_block(65, 80, 500, 0)
true = wait.(fn -> Enum.all?(61..66, &(World.get_block(&1, 80, 500) == 0)) end)

{:ok, saved} = World.init(directory: Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "worlds"))
true = map_size(saved.edited) > 0
IO.puts("Liquid source, falling, region boundary, collision, restart and drainage smoke passed")
