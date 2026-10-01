defmodule Wyram.PluginIrContractsTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Plugin.{CapabilityContribution, Declaration, Diagnostic, SourceLocation}

  test "block refs validate logical plugin and local IDs without a numeric handle" do
    assert {:ok, ref} = Ref.new("wyram", "stone")
    assert Map.from_struct(ref) == %{plugin_id: "wyram", local_id: "stone"}
    assert Ref.canonical_id(ref) == "wyram:stone"
    assert {:error, :invalid_plugin_id} = Ref.new("Wyram", "stone")
    assert {:error, :invalid_local_id} = Ref.new("wyram", "bad:id")
  end

  test "declarations validate kind, role, IDs, and allow templates without persistent IDs" do
    source = source()

    attrs = %{
      plugin_id: "wyram",
      local_id: nil,
      module: WyramMods.Wyram.Blocks.Solid,
      kind: :block,
      role: :template,
      source: source
    }

    assert {:ok, declaration} = Declaration.new(attrs)
    assert declaration.local_id == nil
    assert declaration.role == :template
    assert {:error, %Diagnostic{source: ^source}} = Declaration.new(%{attrs | role: :registered})
    assert {:error, %Diagnostic{source: ^source}} = Declaration.new(%{attrs | kind: :item})
    assert {:error, %Diagnostic{source: ^source}} = Declaration.new(%{attrs | role: :other})
  end

  test "declaration keeps template and capability contributions in source order" do
    source = source()
    template = Declaration.Template.new!(WyramMods.Base.Blocks.Solid, source)

    contribution =
      CapabilityContribution.new!(Wyram.Plugin.Providers.Extension, %{power: 2}, source)

    attrs = %{
      plugin_id: "wyram",
      local_id: "ice",
      module: WyramMods.Wyram.Blocks.Ice,
      kind: :block,
      role: :registered,
      source: source
    }

    assert {:ok, declaration} =
             Declaration.new(Map.put(attrs, :entries, [template, contribution]))

    assert declaration.entries == [template, contribution]
  end

  test "diagnostics retain source positions and related conflict locations" do
    source = source("blocks.ex", 18)
    related = source("base.ex", 7)

    diagnostic =
      Diagnostic.new!(:duplicate_provider, "provider already contributed", source,
        related: [related]
      )

    assert diagnostic.source == source
    assert diagnostic.related == [related]
  end

  defp source(file \\ "blocks.ex", line \\ 3),
    do: struct(SourceLocation, file: file, line: line, column: 1)
end
