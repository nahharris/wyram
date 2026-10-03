defmodule Wyram.LiquidContractsTest do
  use ExUnit.Case, async: true

  alias Wyram.Plugin.{Descriptor, Diagnostic, Provider, SourceLocation}
  alias Wyram.Plugin.Providers.Liquid

  test "liquid settings lower without naming game content" do
    config = struct(Wyram.Capability.Liquid, flow_ms: 200, max_level: 7)
    provider = Liquid
    assert provider in Provider.builtins()
    assert {:ok, %{liquid: %{flow_ms: 200, max_level: 7}}} = provider.lower(config, context())

    for values <- [[flow_ms: 0], [flow_ms: 100.0], [max_level: 0], [max_level: 8]] do
      assert {:error, [%Diagnostic{code: :invalid_liquid}]} =
               provider.validate(struct(Wyram.Capability.Liquid, values), context())
    end
  end

  test "noncolliding liquid and blended material are supported end to end" do
    assert {:ok, %{collision: %{primitive: :none}}} =
             Wyram.Plugin.Providers.Collision.lower(
               struct(Wyram.Capability.Collision, shape: :none),
               context()
             )

    assert {:ok, %{material: material}} =
             Wyram.Plugin.Providers.Material.lower(
               struct(Wyram.Capability.Material,
                 color: {40, 100, 220},
                 mode: :blended,
                 opacity: 160
               ),
               context()
             )

    descriptor = %{
      geometry: %{primitive: :cube},
      collision: %{primitive: :none},
      material: material,
      liquid: %{flow_ms: 200, max_level: 7}
    }

    assert Descriptor.valid?(descriptor)
    refute Descriptor.valid?(put_in(descriptor.collision.primitive, :cube))
    refute Descriptor.valid?(put_in(descriptor.material.opacity, 0))
    refute Descriptor.valid?(Map.put(descriptor, :unknown, true))
  end

  test "emissive materials lower explicitly and invalid opacity is rejected" do
    assert {:ok, %{material: %{color: {240, 80, 10}, mode: :emissive}}} =
             Wyram.Plugin.Providers.Material.lower(
               struct(Wyram.Capability.Material, color: {240, 80, 10}, mode: :emissive),
               context()
             )

    assert {:error, _} =
             Wyram.Plugin.Providers.Material.lower(
               struct(Wyram.Capability.Material, color: {1, 2, 3}, opacity: 12),
               context()
             )
  end

  defp context, do: %{source: %SourceLocation{file: "liquids.ex", line: 1}}

  test "invalid liquid configs retain valid diagnostics with malformed source metadata" do
    for source <- [nil, %SourceLocation{file: "bad.ex", line: 0}] do
      assert {:error, [%Diagnostic{source: valid}]} =
               Liquid.validate(struct(Wyram.Capability.Liquid, flow_ms: 0), %{source: source})

      assert SourceLocation.valid?(valid)
    end
  end
end
