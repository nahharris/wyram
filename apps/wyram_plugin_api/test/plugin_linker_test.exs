defmodule Wyram.Plugin.LinkerTest do
  use ExUnit.Case, async: true

  alias Wyram.Plugin.{Declaration, Linker, SourceLocation}

  defmodule Symbols.A do
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

    def ref, do: Wyram.Block.Ref.new!("a", "one")
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

  defmodule Symbols.BaseBlock do
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

    def ref, do: Wyram.Block.Ref.new!("base", "solid")
  end

  defmodule Symbols.AddonBlock do
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

    def ref, do: Wyram.Block.Ref.new!("addon", "derived")
  end

  defmodule Symbols.One do
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

    def ref, do: Wyram.Block.Ref.new!("a", "one")
  end

  defmodule Symbols.Two do
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

    def ref, do: Wyram.Block.Ref.new!("a", "two")
  end

  test "plugin dependency cycles fail with a path diagnostic" do
    first = plugin("first", ["second"], [])
    second = plugin("second", ["first"], [])

    assert {:error, diagnostics} = Linker.link_set([first, second])
    assert Enum.any?(diagnostics, &(&1.code == :dependency_cycle and length(&1.path) >= 2))
  end

  test "missing explicit dependencies fail before declaration linking" do
    assert {:error, diagnostics} = Linker.link_set([plugin("addon", ["base"], [])])
    assert Enum.any?(diagnostics, &(&1.code == :missing_dependency))
  end

  test "cross-plugin template symbols resolve through declared dependency interfaces" do
    base_block = declaration("base", "solid", Symbols.BaseBlock, :registered, [])

    derived =
      declaration("addon", "derived", Symbols.AddonBlock, :registered, [
        template(Symbols.BaseBlock)
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
    declaration = declaration("a", "one", Symbols.A, :registered, [])

    assert {:ok, linked} = Linker.link_set([plugin("a", [], [declaration])])
    assert Enum.map(linked.catalogs["a"].blocks, & &1.id) == ["a:one"]
    assert Symbols.A.ref() == %Wyram.Block.Ref{plugin_id: "a", local_id: "one"}

    forged = %{declaration | local_id: "forged"}
    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [forged])])
    assert Enum.any?(diagnostics, &(&1.code == :generated_module_mismatch))
  end

  test "template-only declarations are public symbols but never registered blocks" do
    template = declaration("a", nil, Symbols.Template, :template, [])

    assert {:ok, linked} = Linker.link_set([plugin("a", [], [template])])
    assert linked.catalogs["a"].blocks == []
    refute function_exported?(Symbols.Template, :ref, 0)
  end

  test "template cycles report the expansion path and source locations" do
    one = declaration("a", "one", Symbols.One, :registered, [template(Symbols.Two)])
    two = declaration("a", "two", Symbols.Two, :registered, [template(Symbols.One)])

    assert {:error, diagnostics} = Linker.link_set([plugin("a", [], [one, two])])
    assert Enum.any?(diagnostics, &(&1.code == :template_cycle and length(&1.related) >= 1))
  end

  test "unresolved and wrong-role template symbols are rejected" do
    missing = declaration("a", "one", Symbols.One, :registered, [template(Symbols.Absent)])

    template_as_registered =
      declaration("a", "two", Symbols.Two, :registered, [template(Symbols.Template)])

    assert {:error, diagnostics} =
             Linker.link_set([plugin("a", [], [missing, template_as_registered])])

    assert Enum.any?(
             diagnostics,
             &(&1.code in [:unresolved_declaration, :wrong_declaration_role])
           )
  end

  test "duplicate plugin IDs, module symbols and content IDs are rejected" do
    one = declaration("a", "one", Symbols.One, :registered, [])
    two = declaration("a", "two", Symbols.Two, :registered, [])

    assert {:error, diagnostics} =
             Linker.link_set([plugin("a", [], [one]), plugin("a", [], [two])])

    assert Enum.any?(diagnostics, &(&1.code == :duplicate_plugin_id))

    duplicate_id = declaration("a", "one", Symbols.Two, :registered, [])
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

  defp source(file \\ "blocks.ex") do
    %SourceLocation{file: file, line: 8, column: 3, module: __MODULE__}
  end
end
