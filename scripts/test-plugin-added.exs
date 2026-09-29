blocks = Wyram.Engine.PluginManager.blocks()
true = is_integer(blocks["test_addon:prism"])
true = Wyram.Engine.World.get_block(0, 74, 0) == blocks["test_terrain:violet"]
