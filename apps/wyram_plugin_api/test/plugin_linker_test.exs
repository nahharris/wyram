defmodule Wyram.Plugin.LinkerTest do
  use ExUnit.Case, async: true

  alias Wyram.Capability.{Geometry, Material}

  alias Wyram.Plugin.{
    BlockDefaults,
    CapabilityContribution,
    Declaration,
    Diagnostic,
    Linker,
    Provider,
    SourceLocation
  }

  alias Wyram.Plugin.LinkerTest.Symbols.{
    A,
    AddonBlock,
    BaseBlock,
    DeepTemplate,
    One,
    Template,
    Two
  }

  defmodule Symbols.A do
    alias Wyram.Block.Ref

    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "a",
        declaration_module: __MODULE__,
        local_id: "one",
        kind: :block,
        role: :registered,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end

    def ref, do: Ref.new!("a", "one")
  end

  defmodule Symbols.Template do
    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "a",
        declaration_module: __MODULE__,
        local_id: nil,
        kind: :block,
        role: :template,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end
  end

  defmodule Symbols.DeepTemplate do
    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "a",
        declaration_module: __MODULE__,
        local_id: nil,
        kind: :block,
        role: :template,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end
  end

  defmodule Symbols.BaseBlock do
    alias Wyram.Block.Ref

    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "base",
        declaration_module: __MODULE__,
        local_id: "solid",
        kind: :block,
        role: :registered,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end

    def ref, do: Ref.new!("base", "solid")
  end

  defmodule Symbols.AddonBlock do
    alias Wyram.Block.Ref

    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "addon",
        declaration_module: __MODULE__,
        local_id: "derived",
        kind: :block,
        role: :registered,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end

    def ref, do: Ref.new!("addon", "derived")
  end

  defmodule Symbols.One do
    alias Wyram.Block.Ref

    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "a",
        declaration_module: __MODULE__,
        local_id: "one",
        kind: :block,
        role: :registered,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end

    def ref, do: Ref.new!("a", "one")
  end

  defmodule Symbols.Two do
    alias Wyram.Block.Ref

    def __wyram_generated_declaration__ do
      %{
        plugin: Wyram.Plugin.LinkerTest,
        plugin_id: "a",
        declaration_module: __MODULE__,
        local_id: "two",
        kind: :block,
        role: :registered,
        source: %SourceLocation{
          file: "blocks.ex",
          line: 8,
          column: 3,
          module: Wyram.Plugin.LinkerTest
        }
      }
    end

    def ref, do: Ref.new!("a", "two")
  end

  defmodule TintConfig do
    defstruct [:color]
  end

  defmodule ExceptionalConfig do
    defstruct [:phase]
  end

  defmodule ExceptionalProvider do
    @behaviour Provider

    @impl true
    def config_module, do: ExceptionalConfig

    @impl true
    def kinds, do: [:block]

    @impl true
    def config_schema, do: %{phase: :atom}

    @impl true
    def owned_fields, do: %{material: :exclusive}

    @impl true
    def validate(%ExceptionalConfig{phase: :throw}, _context), do: throw(:provider_throw)
    def validate(%ExceptionalConfig{}, _context), do: :ok

    @impl true
    def lower(%ExceptionalConfig{phase: :exit}, _context), do: exit(:provider_exit)

    def lower(%ExceptionalConfig{}, _context),
      do: {:ok, %{material: %{color: {1, 2, 3}, mode: :opaque}}}
  end

  defmodule TintProvider do
    @behaviour Provider

    @impl true
    def config_module, do: TintConfig

    @impl true
    def kinds, do: [:block]

    @impl true
    def config_schema, do: %{color: :rgb8}

    @impl true
    def owned_fields, do: %{material: :exclusive}

    @impl true
    def validate(%TintConfig{color: {r, g, b}}, _context)
        when is_integer(r) and r in 0..255 and is_integer(g) and g in 0..255 and
               is_integer(b) and b in 0..255,
        do: :ok

    def validate(_config, context),
      do:
        {:error,
         [
           Diagnostic.new!(
             :invalid_tint,
             "tint must be RGB8",
             context.source
           )
         ]}

    @impl true
    def lower(%TintConfig{color: color}, _context),
      do: {:ok, %{material: %{color: color, mode: :opaque}}}
  end

  test "plugin dependency cycles fail with a path diagnostic" do
    first = plugin("first", ["second"], [])
    second = plugin("second", ["first"], [])

    assert {:error, diagnostics} = Linker.link_set([first, second])
    assert Enum.any?(diagnostics, &(&1.code == :dependency_cycle and length(&1.path) >= 2))
  end

  test "link inputs reject invalid entry and game module identities" do
    declaration = declaration("a", "one", One, :registered, [])

    assert {:error, diagnostics} =
             Linker.link_set([%{plugin("a", [], [declaration]) | entry: nil}])

    assert Enum.any?(diagnostics, &(&1.code == :invalid_link_input))

    assert {:error, diagnostics} =
             Linker.link_set([%{plugin("a", [], [declaration]) | game: true}])

    assert Enum.any?(diagnostics, &(&1.code == :invalid_link_input))
  end

  test "linker options reject unknown or duplicate keys" do
    declaration = declaration("a", "one", One, :registered, [])
    input = plugin("a", [], [declaration])

    assert {:error, diagnostics} = Linker.link_set([input], unknown_option: true)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_link_options))

    assert {:error, diagnostics} =
             Linker.link_set([input], max_template_expansions: 1, max_template_expansions: 2)

    assert Enum.any?(diagnostics, &(&1.code == :invalid_link_options))
  end

  test "template expansion budget rejects before following an over-budget edge" do
    template_decl = declaration("a", nil, Template, :template, [template(DeepTemplate)])
    nested_template = declaration("a", nil, DeepTemplate, :template, [])
    block = declaration("a", "one", One, :registered, [template(Template)])

    assert {:error, diagnostics} =
             Linker.link_set([plugin("a", [], [template_decl, nested_template, block])],
               max_template_expansions: 1
             )

    assert Enum.any?(diagnostics, &(&1.code == :template_expansion_budget_exceeded))
  end

  test "provider throws and exits become source-aware link diagnostics" do
    for phase <- [:throw, :exit] do
      contribution = contribution(ExceptionalProvider, %ExceptionalConfig{phase: phase})
      block = declaration("a", "one", One, :registered, [contribution])

      input = %{plugin("a", [], [block]) | providers: [ExceptionalProvider]}
      assert {:error, diagnostics} = Linker.link_set([input])
      assert Enum.any?(diagnostics, &(&1.code == :provider_execution_failed))
      assert Enum.all?(diagnostics, &match?(%Diagnostic{source: %SourceLocation{}}, &1))
    end
  end

  test "dependency closures reject conflicting definitions of the same plugin id" do
    base_a = plugin("base", [], [])
    base_b = %{base_a | providers: [TintProvider]}
    left = plugin("left", [], [])
    right = plugin("right", [], [])

    interfaces = %{
      "left" => %{plugins: [left, base_a]},
      "right" => %{plugins: [right, base_b]}
    }

    consumer = %{plugin("consumer", ["left", "right"], []) | entry: __MODULE__}

    assert {:error, diagnostics} = Linker.link_plugin(consumer, [], interfaces, [])
    assert Enum.any?(diagnostics, &(&1.code == :conflicting_dependency_interface))
  end

  test "missing explicit dependencies fail before declaration linking" do
    assert {:error, diagnostics} = Linker.link_set([plugin("addon", ["base"], [])])
    assert Enum.any?(diagnostics, &(&1.code == :missing_dependency))
  end

  test "cross-plugin template symbols resolve through declared dependency interfaces" do
    base_block = declaration("base", "solid", BaseBlock, :registered, [])

    derived =
      declaration("addon", "derived", AddonBlock, :registered, [
        template(BaseBlock)
      ])

    assert {:ok, linked} =
             Linker.link_set([
               plugin("addon", ["base"], [derived]),
               plugin("base", [], [base_block])
             ])

    assert linked.order == ["base", "addon"]
    assert Enum.map(linked.catalogs["addon"].blocks, & &1.id) == ["addon:derived"]

    assert {:error, diagnostics} =
             Linker.link_set([plugin("addon", [], [derived]), plugin("base", [], [base_block])])

    assert Enum.any?(diagnostics, &(&1.code == :undeclared_dependency_reference))
  end

  test "generated module metadata must exactly match its collected declaration" do
    declaration = declaration("a", "one", A, :registered, [])

    assert {:ok, linked} = Linker.link_set([plugin("a", [], [declaration])])
    assert Enum.map(linked.catalogs["a"].blocks, & &1.id) == ["a:one"]
    assert A.ref() == %Wyram.Block.Ref{plugin_id: "a", local_id: "one"}

    forged = %{declaration | local_id: "forged"}
    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [forged])])
    assert Enum.any?(diagnostics, &(&1.code == :generated_module_mismatch))
  end

  test "linked block descriptors include defaults applied after authored composition" do
    block = declaration("a", "one", One, :registered, [])
    assert {:ok, linked} = Linker.link_set([plugin("a", [], [block])])

    [block] = linked.catalogs["a"].blocks
    assert block.id == "a:one"

    assert block.descriptor == %{
             geometry: %{primitive: :cube},
             collision: %{primitive: :cube},
             material: %{color: {255, 255, 255}, mode: :opaque}
           }

    assert Enum.all?(block.entries, &(&1.origin == :default))

    assert Enum.map(block.entries, & &1.provider) ==
             Enum.map(BlockDefaults.entries(source()), & &1.provider)
  end

  test "liquid declarations require explicit noncollision after template composition" do
    liquid = contribution(Wyram.Plugin.Providers.Liquid, %Wyram.Capability.Liquid{})
    block = declaration("a", "one", One, :registered, [liquid])

    assert {:error, [%Diagnostic{code: :invalid_capability_composition}]} =
             Linker.link_set([plugin("a", [], [block])])

    collision =
      contribution(Wyram.Plugin.Providers.Collision, %Wyram.Capability.Collision{shape: :none})

    block = %{block | entries: [liquid, collision]}
    assert {:ok, linked} = Linker.link_set([plugin("a", [], [block])])
    assert hd(linked.catalogs["a"].blocks).descriptor.liquid.max_level == 7
  end

  test "extension provider can author supported RGB material output and suppresses material default" do
    block =
      declaration("a", "one", One, :registered, [
        contribution(TintProvider, %TintConfig{color: {12, 34, 56}})
      ])

    input = %{plugin("a", [], [block]) | providers: [TintProvider]}
    assert {:ok, linked} = Linker.link_set([input])
    [linked_block] = linked.catalogs["a"].blocks
    assert linked_block.descriptor.material == %{color: {12, 34, 56}, mode: :opaque}
    assert length(linked_block.entries) == 3
    refute Enum.any?(linked_block.entries, &(&1.provider == Wyram.Plugin.Providers.Material))
  end

  test "provider duplication requires an existing authored target and whole replacement" do
    geometry = %Geometry{shape: %Wyram.Shape.Cube{}}

    duplicate =
      declaration("a", "one", One, :registered, [
        contribution(Wyram.Plugin.Providers.Geometry, geometry),
        contribution(Wyram.Plugin.Providers.Geometry, geometry)
      ])

    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [duplicate])])
    assert Enum.any?(diagnostics, &(&1.code == :duplicate_provider))

    no_target =
      declaration("a", "one", One, :registered, [
        contribution(Wyram.Plugin.Providers.Geometry, geometry, true)
      ])

    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [no_target])])
    assert Enum.any?(diagnostics, &(&1.code == :missing_override_target))
  end

  test "core and extension providers cannot both own the material descriptor field" do
    block =
      declaration("a", "one", One, :registered, [
        contribution(TintProvider, %TintConfig{color: {12, 34, 56}}),
        contribution(Wyram.Plugin.Providers.Material, %Material{
          color: {90, 80, 70},
          mode: :opaque
        })
      ])

    input = %{plugin("a", [], [block]) | providers: [TintProvider]}
    assert {:error, diagnostics} = Linker.link_set([input])
    assert Enum.any?(diagnostics, &(&1.code == :descriptor_field_conflict))
  end

  test "unsupported material modes and lowerer output fields fail before catalog emission" do
    unsupported =
      declaration("a", "one", Symbols.One, :registered, [
        contribution(Wyram.Plugin.Providers.Material, %Material{color: {1, 2, 3}, mode: :cutout})
      ])

    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [unsupported])])
    assert Enum.any?(diagnostics, &(&1.code == :unsupported_material_mode))
  end

  test "template-only declarations are public symbols but never registered blocks" do
    template = declaration("a", nil, Template, :template, [])

    assert {:ok, linked} = Linker.link_set([plugin("a", [], [template])])
    assert linked.catalogs["a"].blocks == []
    refute function_exported?(Template, :ref, 0)
  end

  test "template cycles report the expansion path and source locations" do
    one = declaration("a", "one", One, :registered, [template(Two)])
    two = declaration("a", "two", Two, :registered, [template(One)])

    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [one, two])])
    assert Enum.any?(diagnostics, &(&1.code == :template_cycle and &1.related != []))
  end

  test "unresolved and wrong-role template symbols are rejected" do
    missing = declaration("a", "one", One, :registered, [template(Symbols.Absent)])

    template_as_registered =
      declaration("a", "two", Two, :registered, [template(Template)])

    assert {:error, diagnostics} =
             Linker.link_set([plugin("a", [], [missing, template_as_registered])])

    assert Enum.any?(
             diagnostics,
             &(&1.code in [:unresolved_declaration, :wrong_declaration_role])
           )
  end

  test "duplicate plugin IDs, module symbols and content IDs are rejected" do
    one = declaration("a", "one", One, :registered, [])
    two = declaration("a", "two", Two, :registered, [])

    assert {:error, diagnostics} =
             Linker.link_set([plugin("a", [], [one]), plugin("a", [], [two])])

    assert Enum.any?(diagnostics, &(&1.code == :duplicate_plugin_id))

    duplicate_id = declaration("a", "one", Two, :registered, [])
    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [one, duplicate_id])])

    assert Enum.any?(
             diagnostics,
             &(&1.code in [:duplicate_content_id, :duplicate_declaration_module])
           )
  end

  defp plugin(id, dependencies, declarations) do
    %{
      id: id,
      entry: __MODULE__,
      dependencies: dependencies,
      declarations: declarations,
      providers: [],
      modules: Enum.map(declarations, & &1.module),
      game: nil
    }
  end

  defp declaration(plugin_id, local_id, module, role, entries) do
    %Declaration{
      plugin_id: plugin_id,
      local_id: local_id,
      module: module,
      kind: :block,
      role: role,
      source: source(),
      entries: entries
    }
  end

  defp template(module), do: %Declaration.Template{module: module, source: source()}

  defp contribution(provider, config, override \\ false) do
    CapabilityContribution.new!(provider, config, source(), override: override)
  end

  defp source(file \\ "blocks.ex") do
    %SourceLocation{file: file, line: 8, column: 3, module: __MODULE__}
  end
end
