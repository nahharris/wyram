blocks = Wyram.Engine.PluginManager.blocks()
true = is_integer(blocks["example:amber"])
true = Wyram.Engine.World.get_block(0, 74, 0) == blocks["official:grass"]
