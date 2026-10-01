defmodule Wyram.PluginDslTest do
  use ExUnit.Case, async: false

  alias Wyram.PluginDslFixture.{CapabilityCatalog, DeclarationCatalog, TemplateCatalog}

  test "entry metadata preserves declared contributors, providers, and default dependencies" do
    [{entry_module, _entry_binary}, {_catalog_module, _catalog_binary}] =
      Code.compile_string("""
      defmodule Wyram.PluginDslFixture.Entry do
        use Wyram.Plugin,
          id: "fixture",
          declarations: [Wyram.PluginDslFixture.Catalog],
          providers: [Wyram.PluginDslFixture.Provider],
          game: Wyram.PluginDslFixture.Game
      end

      defmodule Wyram.PluginDslFixture.Catalog do
        use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.Entry
      end
      """)

    assert entry_module.__wyram_plugin__() == %{
             id: "fixture",
             dependencies: [],
             declaration_modules: [
               Wyram.PluginDslFixture.Entry,
               Wyram.PluginDslFixture.Catalog
             ],
             providers: [Wyram.PluginDslFixture.Provider],
             game: Wyram.PluginDslFixture.Game
           }
  end

  test "plugin entry modules collect inline declarations and expose their block refs" do
    expected_entry = Wyram.PluginDslFixture.InlineEntry

    entry_module =
      Code.compile_string("""
      defmodule Wyram.PluginDslFixture.InlineEntry do
        use Wyram.Plugin, id: "inline-fixture"

        defblock Stone, id: "stone"
        def stone_ref, do: __MODULE__.Blocks.Stone.ref()
      end
      """)
      |> Enum.find_value(fn
        {^expected_entry, _binary} -> expected_entry
        _compiled -> nil
      end)

    assert entry_module == expected_entry

    assert entry_module.__wyram_plugin__().declaration_modules == [entry_module]
    [declaration] = entry_module.__wyram_declarations__()
    assert declaration.module == Wyram.PluginDslFixture.InlineEntry.Blocks.Stone
    assert declaration.local_id == "stone"

    reference = entry_module.stone_ref()
    assert Map.from_struct(reference) == %{plugin_id: "inline-fixture", local_id: "stone"}
  end

  test "recompiling a declaration accepts its existing matching generated marker" do
    suffix = System.unique_integer([:positive])
    entry = "Wyram.PluginDslFixture.Recompiled#{suffix}"
    catalog = "#{entry}.Catalog"

    source = """
    defmodule #{entry} do
      use Wyram.Plugin, id: "recompiled-fixture", declarations: [#{catalog}]
    end

    defmodule #{catalog} do
      use Wyram.Plugin.Declarations, plugin: #{entry}
      defblock Stone, id: "stone"
    end
    """

    Code.compile_string(source, "same_vm_recompile.ex")

    block_module = Module.concat([entry, "Blocks.Stone"])
    original_marker = block_module.__wyram_generated_declaration__()

    Code.compile_string(source, "same_vm_recompile.ex")

    recompiled_marker = block_module.__wyram_generated_declaration__()

    assert recompiled_marker == original_marker
  end

  test "defblock records a registered block and its aliased template in source order" do
    Code.compile_string("""
    defmodule Wyram.PluginDslFixture.DeclarationEntry do
      use Wyram.Plugin, id: "fixture", declarations: [Wyram.PluginDslFixture.DeclarationCatalog]
    end

    defmodule Wyram.PluginDslFixture.Shared do
    end

    defmodule Wyram.PluginDslFixture.DeclarationCatalog do
      alias Wyram.PluginDslFixture.Shared, as: Base
      use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.DeclarationEntry

      defblock Stone, id: "stone" do
        template Base
      end
    end
    """)

    [declaration] = invoke(DeclarationCatalog, :__wyram_declarations__, [])

    assert declaration.plugin_id == nil
    assert declaration.plugin == Wyram.PluginDslFixture.DeclarationEntry
    assert declaration.local_id == "stone"
    assert declaration.module == Wyram.PluginDslFixture.DeclarationEntry.Blocks.Stone
    assert declaration.kind == :block
    assert declaration.role == :registered
    assert [template] = declaration.entries
    assert template.module == Wyram.PluginDslFixture.Shared
    assert declaration.source.line > 0

    assert invoke(
             Wyram.PluginDslFixture.DeclarationEntry.Blocks.Stone,
             :__wyram_generated_declaration__,
             []
           ) == %{
             plugin: Wyram.PluginDslFixture.DeclarationEntry,
             declaration_module: Wyram.PluginDslFixture.DeclarationEntry.Blocks.Stone,
             local_id: "stone",
             kind: :block,
             role: :registered,
             source: declaration.source
           }

    reference = invoke(Wyram.PluginDslFixture.DeclarationEntry.Blocks.Stone, :ref, [])

    assert Map.from_struct(reference) == %{plugin_id: "fixture", local_id: "stone"}
  end

  test "template declarations have no id and do not expose placement references" do
    Code.compile_string("""
    defmodule Wyram.PluginDslFixture.TemplateEntry do
      use Wyram.Plugin, id: "fixture", declarations: [Wyram.PluginDslFixture.TemplateCatalog]
    end

    defmodule Wyram.PluginDslFixture.TemplateCatalog do
      use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.TemplateEntry
      defblock CubeTemplate, template: true do
      end
    end
    """)

    [declaration] = invoke(TemplateCatalog, :__wyram_declarations__, [])
    refute declaration.local_id
    assert declaration.role == :template
    refute function_exported?(Wyram.PluginDslFixture.TemplateEntry.Blocks.CubeTemplate, :ref, 0)
  end

  test "entry and declaration macros reject unknown options and executable identity expressions" do
    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.BadEntry do
        use Wyram.Plugin, id: "fixture", misspelled: true
      end
      """,
      ~r/unknown.*option|unsupported.*option/i
    )

    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.DuplicateEntryOptions do
        use Wyram.Plugin, id: "fixture", id: "duplicate"
      end
      """,
      ~r/unique literal keyword list/i
    )

    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.ComputedId do
        use Wyram.Plugin, id: send(self(), :executed)
      end
      """,
      ~r/id.*literal|literal.*id/i
    )

    refute_received :executed
  end

  test "template role rejects a persistent id" do
    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.InvalidTemplateEntry do
        use Wyram.Plugin, id: "fixture", declarations: [Wyram.PluginDslFixture.InvalidTemplateCatalog]
      end

      defmodule Wyram.PluginDslFixture.InvalidTemplateCatalog do
        use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.InvalidTemplateEntry
        defblock InvalidTemplate, id: "invalid", template: true
      end
      """,
      ~r/template.*id|id.*template/i
    )
  end

  test "capability entries preserve nested literal structs and override in source order" do
    Code.compile_string("""
    defmodule Wyram.PluginDslFixture.Config.Nested do
      defstruct [:value]
    end

    defmodule Wyram.PluginDslFixture.Config.Material do
      defstruct [:color, :details]
    end

    defmodule Wyram.PluginDslFixture.CapabilityEntry do
      use Wyram.Plugin,
        id: "fixture",
        declarations: [Wyram.PluginDslFixture.CapabilityCatalog]
    end

    defmodule Wyram.PluginDslFixture.CapabilityCatalog do
      alias Wyram.PluginDslFixture.Config.{Material, Nested}
      use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.CapabilityEntry

      defblock Gem, id: "gem" do
        template Wyram.PluginDslFixture.Config.Base
        capability %Material{
          color: {-1, 2.5, [:opaque, nil, true]},
          details: %Nested{value: %{message: "literal"}}
        }, override: true
      end
    end
    """)

    [declaration] = invoke(CapabilityCatalog, :__wyram_declarations__, [])

    [template, capability] = declaration.entries
    assert template.module == Wyram.PluginDslFixture.Config.Base
    assert capability.config_module == Wyram.PluginDslFixture.Config.Material
    assert capability.override
    assert capability.source.line > 0
    assert capability.config.module == Wyram.PluginDslFixture.Config.Material

    assert capability.config.fields == %{
             color: {-1, 2.5, [:opaque, nil, true]},
             details: %Wyram.Plugin.DSL.StructLiteral{
               module: Wyram.PluginDslFixture.Config.Nested,
               fields: %{value: %{message: "literal"}}
             }
           }
  end

  test "capability expressions reject executable calls before running them" do
    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.UnsafeEntry do
        use Wyram.Plugin, id: "fixture", declarations: [Wyram.PluginDslFixture.UnsafeCatalog]
      end

      defmodule Wyram.PluginDslFixture.Unsafe.Config.Material do
        defstruct [:color]
      end

      defmodule Wyram.PluginDslFixture.UnsafeCatalog do
        alias Wyram.PluginDslFixture.Unsafe.Config.Material
        use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.UnsafeEntry
        defblock Unsafe, id: "unsafe" do
          capability %Material{color: send(self(), :executed)}
        end
      end
      """,
      ~r/literal values/i
    )

    refute_received :executed
  end

  test "capability expressions reject variables, calls, anonymous functions, and module attributes" do
    for expression <- [
          "value",
          "local_config()",
          "Wyram.PluginDslFixture.Helpers.config()",
          "fn -> :opaque end",
          "@material"
        ] do
      assert_compile_error(capability_fixture(expression), ~r/literal values/i)
    end
  end

  test "declaration and capability options reject invalid roles, IDs, and unknown keys" do
    for declaration <- [
          "defblock Bad, id: \"Bad ID\"",
          "defblock Bad, id: \"bad\", template: 1",
          "defblock Bad, id: \"bad\", unknown: true",
          "defblock Bad, id: \"bad\" do def nested, do: :not_allowed end",
          "defblock Bad, template: true, id: \"bad\""
        ] do
      assert_compile_error(declaration_fixture(declaration), ~r/(id|template|option)/i)
    end

    assert_compile_error(
      capability_fixture("%Material{color: :opaque}", "override: 1"),
      ~r/override must be a boolean literal/i
    )

    assert_compile_error(
      capability_fixture("%Material{color: :opaque}", "typo: true"),
      ~r/unknown capability option/i
    )
  end

  test "declaration collection guards modules already owned by handwritten code" do
    assert_compile_error(
      """
      defmodule Wyram.PluginDslFixture.CollisionEntry.Blocks.Stone do
        def handwritten?, do: true
      end

      defmodule Wyram.PluginDslFixture.CollisionEntry do
        use Wyram.Plugin,
          id: "fixture",
          declarations: [Wyram.PluginDslFixture.CollisionCatalog]
      end

      defmodule Wyram.PluginDslFixture.CollisionCatalog do
        use Wyram.Plugin.Declarations, plugin: Wyram.PluginDslFixture.CollisionEntry
        defblock Stone, id: "stone"
      end
      """,
      ~r/already defined/i
    )
  end

  defp assert_compile_error(source, message) do
    assert_raise CompileError, message, fn ->
      Code.compile_string(source, "plugin_dsl_fixture.ex")
    end
  end

  defp invoke(module, function, arguments), do: apply(module, function, arguments)

  defp capability_fixture(expression, options \\ "") do
    suffix = System.unique_integer([:positive])
    entry = "Wyram.PluginDslFixture.Validation#{suffix}"
    catalog = "#{entry}.Catalog"
    config = "#{entry}.Config.Material"
    options = if options == "", do: "", else: ", #{options}"

    """
    defmodule #{entry} do
      use Wyram.Plugin, id: "fixture", declarations: [#{catalog}]
    end

    defmodule #{config} do
      defstruct [:color]
    end

    defmodule #{catalog} do
      alias #{config}, as: Material
      use Wyram.Plugin.Declarations, plugin: #{entry}
      defblock Stone, id: "stone" do
        capability #{expression}#{options}
      end
    end
    """
  end

  defp declaration_fixture(declaration) do
    suffix = System.unique_integer([:positive])
    entry = "Wyram.PluginDslFixture.Validation#{suffix}"
    catalog = "#{entry}.Catalog"

    """
    defmodule #{entry} do
      use Wyram.Plugin, id: "fixture", declarations: [#{catalog}]
    end

    defmodule #{catalog} do
      use Wyram.Plugin.Declarations, plugin: #{entry}
      #{declaration}
    end
    """
  end
end
