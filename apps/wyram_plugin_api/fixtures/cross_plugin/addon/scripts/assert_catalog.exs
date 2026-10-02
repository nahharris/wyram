base_path = Application.app_dir(:wyram_cross_plugin_base, "priv/wyram/catalog.term")
addon_path = Application.app_dir(:wyram_cross_plugin_addon, "priv/wyram/catalog.term")

for app <- [:wyram_plugin_api, :wyram_cross_plugin_base, :wyram_cross_plugin_addon] do
  case :application.load(app) do
    :ok -> :ok
    {:error, {:already_loaded, ^app}} -> :ok
  end

  Enum.each(Application.spec(app, :modules) || [], &Code.ensure_loaded/1)
end

base = :erlang.binary_to_term(File.read!(base_path), [:safe])
addon = :erlang.binary_to_term(File.read!(addon_path), [:safe])

unless addon.dependency_interfaces["fixture-base"] == base.interface_fingerprint do
  raise "addon dependency fingerprint does not match the built base interface"
end

unless Wyram.Plugin.Compiler.fingerprint(addon.interface) == addon.interface_fingerprint do
  raise "addon interface fingerprint does not match its compiled interface"
end

unless not Map.has_key?(base.interface, :plugins) and
         Enum.all?(base.interface.declarations, &(&1.entries == [])) and
         :binary.match(base.interface.compile_data, "terrain_catalog_only_atom") != :nomatch do
  raise "base interface must export safe declaration summaries and preserve authored compile data"
end

expected_terrain =
  Map.new([:surface, :soil, :rock], fn role ->
    {role, Wyram.Block.Ref.new!("fixture-base", "stone")}
  end)

unless match?(%Wyram.Game.Config{}, addon.catalog.game) and
         addon.catalog.game.terrain == expected_terrain do
  raise "addon game configuration did not preserve its dependency terrain references"
end

block = Enum.find(addon.catalog.blocks, &(&1.local_id == "cobble"))
base_block = Enum.find(base.catalog.blocks, &(&1.local_id == "stone"))
{r, g, b} = base_block.descriptor.material.color

unless block && base_block && block.descriptor == base_block.descriptor &&
         block.descriptor.geometry == %{primitive: :cube} &&
         block.descriptor.collision == %{primitive: :cube} &&
         block.descriptor.material.mode == :opaque &&
         Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255)) do
  raise "template expansion did not inherit the base block descriptor"
end

IO.puts("BASE_FP=#{base.interface_fingerprint}")
IO.puts("ADDON_DEP_FP=#{addon.dependency_interfaces["fixture-base"]}")
IO.puts("ADDON_FP=#{addon.interface_fingerprint}")
