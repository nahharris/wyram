defmodule Wyram.PluginContractsTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Capability.{Collision, Geometry, Material}
  alias Wyram.Plugin.{CapabilityContribution, Declaration, Diagnostic, Provider, SourceLocation}

  defmodule ExtensionConfig do
    defstruct [:strength]
  end

  defmodule ExtensionProvider do
    @behaviour Provider

    @impl true
    def config_module, do: ExtensionConfig

    @impl true
    def kinds, do: [:block]

    @impl true
    def config_schema, do: %{strength: {:integer, 1..10}}

    @impl true
    def owned_fields, do: %{material: :exclusive}

    @impl true
    def validate(%ExtensionConfig{strength: strength}, _context)
        when is_integer(strength) and strength in 1..10,
        do: :ok

    def validate(_config, context),
      do:
        {:error,
         [
           Diagnostic.new!(
             :invalid_extension_config,
             "strength must be an integer from 1 to 10",
             context.source
           )
         ]}

    @impl true
    def lower(%ExtensionConfig{strength: strength}, _context),
      do: {:ok, %{material: %{color: {strength, 0, 0}, mode: :opaque}}}
  end

  defmodule IncompleteProvider do
    def config_module, do: ExtensionConfig
  end

  test "plugin and local IDs are validated and refs remain logical identities" do
    assert {:ok, ref} = Ref.new("wyram", "stone")
    assert ref.plugin_id == "wyram"
    assert ref.local_id == "stone"
    ref_fields = Map.keys(Map.from_struct(ref))
    assert Enum.sort(ref_fields) == [:local_id, :plugin_id]

    assert {:error, _} = Ref.new("Bad Namespace", "stone")
    assert {:error, _} = Ref.new("wyram", "contains:colon")
    assert {:error, _} = Ref.new("wyram", "")
  end

  test "declaration validates kind and role while templates need no persistent ID" do
    source = source()

    assert {:ok, declaration} =
             Declaration.new(%{
               plugin_id: "wyram",
               local_id: nil,
               module: WyramMods.Wyram.Blocks.Solid,
               kind: :block,
               role: :template,
               source: source
             })

    assert declaration.role == :template

    assert {:error, _} =
             Declaration.new(%{
               plugin_id: "wyram",
               local_id: nil,
               module: WyramMods.Wyram.Blocks.Bad,
               kind: :block,
               role: :registered,
               source: source
             })

    assert {:error, _} =
             Declaration.new(%{
               plugin_id: "wyram",
               local_id: "a",
               module: WyramMods.Wyram.Blocks.Bad,
               kind: :item,
               role: :registered,
               source: source
             })

    assert {:error, _} =
             Declaration.new(%{
               plugin_id: "wyram",
               local_id: "a",
               module: WyramMods.Wyram.Blocks.Bad,
               kind: :block,
               role: :secret,
               source: source
             })
  end

  test "declaration entries preserve template and provider source order" do
    location = source()
    template = Declaration.Template.new!(WyramMods.Base.Blocks.Solid, location)

    geometry =
      CapabilityContribution.new!(
        Geometry,
        struct(Geometry, shape: struct(Wyram.Shape.Cube)),
        location
      )

    assert {:ok, declaration} =
             Declaration.new(%{
               plugin_id: "wyram",
               local_id: "ice",
               module: WyramMods.Wyram.Blocks.Ice,
               kind: :block,
               role: :registered,
               source: location,
               entries: [template, geometry]
             })

    assert declaration.entries == [template, geometry]
  end

  test "diagnostics retain source and related conflict locations" do
    primary = source("blocks.ex", 18)
    previous = source("base.ex", 7)

    diagnostic =
      Diagnostic.new!(:duplicate_provider, "provider already contributed", primary,
        related: [previous]
      )

    assert diagnostic.source == primary
    assert diagnostic.related == [previous]
    assert diagnostic.code == :duplicate_provider
  end

  test "built-in providers validate concrete configs and lower supported cube primitives" do
    context = %{source: source()}
    cube = struct(Wyram.Shape.Cube)
    geometry = struct(Geometry, shape: cube)
    collision = struct(Collision, shape: cube)
    material = struct(Material, color: {160, 160, 160}, mode: :opaque)

    assert {:ok, %{geometry: %{primitive: :cube}}} =
             Wyram.Plugin.Providers.Geometry.lower(geometry, context)

    assert {:ok, %{collision: %{primitive: :cube}}} =
             Wyram.Plugin.Providers.Collision.lower(collision, context)

    assert {:ok, %{material: %{color: {160, 160, 160}, mode: :opaque}}} =
             Wyram.Plugin.Providers.Material.lower(material, context)

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Material.validate(%{material | color: {256, 0, 0}}, context)

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Material.validate(
               material |> Map.put(:mode, :blended) |> Map.put(:extra, true),
               context
             )

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Geometry.validate(struct(Geometry, shape: :sphere), context)

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Collision.validate(struct(Collision, shape: :sphere), context)

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Material.validate(
               struct(Material, color: {1, 2, 3}, mode: :blended),
               context
             )

    cube_with_unknown_field = Map.put(cube, :radius, 2)

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Geometry.validate(
               struct(Geometry, shape: cube_with_unknown_field),
               context
             )

    assert {:error, [_]} =
             Wyram.Plugin.Providers.Material.validate(
               struct(Material, color: :invalid, mode: :opaque),
               %{}
             )
  end

  test "field ownership rejects collisions and extension providers use the same contract" do
    assert Provider.builtins() == [
             Wyram.Plugin.Providers.Geometry,
             Wyram.Plugin.Providers.Collision,
             Wyram.Plugin.Providers.Material
           ]

    assert Provider.ownership_conflicts([
             Wyram.Plugin.Providers.Geometry,
             Wyram.Plugin.Providers.Collision
           ]) == []

    assert [
             %{
               field: :material,
               providers: [Wyram.Plugin.Providers.Material, Wyram.Plugin.Providers.Material]
             }
           ] =
             Provider.ownership_conflicts([
               Wyram.Plugin.Providers.Material,
               Wyram.Plugin.Providers.Material
             ])

    assert [
             %{field: :material, providers: [Wyram.Plugin.Providers.Material, ExtensionProvider]}
           ] = Provider.ownership_conflicts([Wyram.Plugin.Providers.Material, ExtensionProvider])

    assert Provider.for_config(ExtensionConfig, [ExtensionProvider]) == {:ok, ExtensionProvider}

    assert Provider.for_config(ExtensionConfig, [ExtensionProvider, ExtensionProvider]) ==
             {:error, :ambiguous_provider}

    assert Provider.for_config(ExtensionConfig, [IncompleteProvider]) ==
             {:error, :unknown_provider}

    assert Provider.for_config(ExtensionConfig, [false]) == {:error, :unknown_provider}
    assert Provider.for_config(true, [ExtensionProvider]) == {:error, :unknown_provider}
    assert :ok = ExtensionProvider.validate(%ExtensionConfig{strength: 5}, %{source: source()})

    assert {:ok, %{material: %{color: {5, 0, 0}, mode: :opaque}}} =
             ExtensionProvider.lower(%ExtensionConfig{strength: 5}, %{})

    assert {:error, [_]} =
             ExtensionProvider.validate(%ExtensionConfig{strength: 11}, %{source: source()})
  end

  test "block defaults are explicit solid opaque contributions" do
    defaults = Wyram.Plugin.BlockDefaults.entries(source())

    assert Enum.map(defaults, & &1.provider) == [
             Wyram.Plugin.Providers.Geometry,
             Wyram.Plugin.Providers.Collision,
             Wyram.Plugin.Providers.Material
           ]

    assert Enum.all?(defaults, &(&1.origin == :default and &1.override == false))

    assert {:ok, %{material: %{color: {255, 255, 255}, mode: :opaque}}} =
             Wyram.Plugin.Providers.Material.lower(Enum.at(defaults, 2).config, %{
               source: source()
             })
  end

  defp source(file \\ "blocks.ex", line \\ 3),
    do: struct(SourceLocation, file: file, line: line, column: 1)
end
