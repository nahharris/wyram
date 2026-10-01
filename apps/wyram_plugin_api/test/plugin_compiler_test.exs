defmodule Wyram.Plugin.CompilerTest do
  use ExUnit.Case, async: false

  alias Wyram.Plugin.Compiler

  test "writes a deterministic descriptor catalog and exact owned BEAM hashes" do
    fixture = compile_fixture("stone", "compiler-fixture", [], nil)

    path = temp_path("catalog")

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(fixture.compile_path)
    end)

    assert {:ok, first} =
             Compiler.compile_entry(fixture.entry,
               catalog_path: path,
               compile_path: fixture.compile_path
             )

    assert {:ok, bytes1} = File.read(path)
    assert first.magic == :wyram_plugin_catalog
    assert first.plugin.id == "compiler-fixture"
    assert first.plugin.entry == Atom.to_string(fixture.entry)

    assert first.catalog.blocks |> hd() |> Map.fetch!(:descriptor) == %{
             geometry: %{primitive: :cube},
             collision: %{primitive: :cube},
             material: %{color: {255, 255, 255}, mode: :opaque}
           }

    assert Enum.sort(Map.keys(first.interface.module_hashes)) == first.plugin.owned_modules
    assert first.interface.modules == first.plugin.owned_modules
    assert first.interface_fingerprint == Compiler.fingerprint(first.interface)
    refute Map.has_key?(hd(first.catalog.blocks), :entries)

    assert {:ok, _second} =
             Compiler.compile_entry(fixture.entry,
               catalog_path: path,
               compile_path: fixture.compile_path
             )

    assert {:ok, ^bytes1} = File.read(path)
  end

  test "failed compilation removes a previous catalog artifact" do
    path = temp_path("stale-catalog")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "old catalog")

    assert {:error, [_]} = Compiler.compile_entry(__MODULE__, catalog_path: path)
    refute File.exists?(path)
  end

  test "precompile invalidation removes the previous catalog before Elixir recompilation" do
    path = Compiler.catalog_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "stale")

    assert {:ok, []} = Mix.Tasks.Compile.WyramPrepare.run([])
    refute File.exists?(path)
  end

  test "compiler rejects metadata modules absent from the app's compiled BEAM set" do
    fixture = compile_fixture("missing", "compiler-missing", [], nil)
    path = temp_path("missing-module")
    empty_compile_path = temp_path("empty-beams")
    File.mkdir_p!(empty_compile_path)

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(empty_compile_path)
      File.rm_rf(fixture.compile_path)
    end)

    assert {:error, [diagnostic]} =
             Compiler.compile_entry(fixture.entry,
               catalog_path: path,
               compile_path: empty_compile_path
             )

    assert diagnostic.code == :module_ownership_mismatch
    refute File.exists?(path)
  end

  test "dependent compilation preserves exact interface fingerprints and expands dependency templates" do
    base = compile_fixture("base", "compiler-base", [], nil)
    addon = compile_fixture("addon", "compiler-addon", ["compiler-base"], base.block_module)
    base_path = temp_path("base-catalog")
    addon_path = temp_path("addon-catalog")

    on_exit(fn ->
      File.rm(base_path)
      File.rm(addon_path)
      File.rm_rf(base.compile_path)
      File.rm_rf(addon.compile_path)
    end)

    assert {:ok, base_artifact} =
             Compiler.compile_entry(base.entry,
               catalog_path: base_path,
               compile_path: base.compile_path
             )

    assert {:ok, addon_artifact} =
             Compiler.compile_entry(addon.entry,
               catalog_path: addon_path,
               compile_path: addon.compile_path,
               dependencies: %{
                 "compiler-base" => %{
                   interface: base_artifact.interface,
                   interface_fingerprint: base_artifact.interface_fingerprint
                 }
               }
             )

    assert addon_artifact.dependency_interfaces == %{
             "compiler-base" => base_artifact.interface_fingerprint
           }

    assert hd(addon_artifact.catalog.blocks).descriptor ==
             hd(base_artifact.catalog.blocks).descriptor

    assert addon_artifact.interface_fingerprint == Compiler.fingerprint(addon_artifact.interface)
  end

  defp compile_fixture(suffix, plugin_id, dependencies, template_module) do
    module_prefix = "Wyram.Plugin.CompilerFixture#{String.capitalize(suffix)}"
    entry_name = "#{module_prefix}.Entry"
    blocks_name = "#{module_prefix}.Blocks"
    body = if template_module, do: "template(#{inspect(template_module)})", else: ""

    source = """
    defmodule #{entry_name} do
      use Wyram.Plugin,
        id: #{inspect(plugin_id)},
        dependencies: #{inspect(dependencies)},
        declarations: [#{blocks_name}]
    end

    defmodule #{blocks_name} do
      use Wyram.Plugin.Declarations, plugin: #{entry_name}
      defblock Stone, id: "stone" do
        #{body}
      end
    end
    """

    compile_path = temp_path("beams")
    File.mkdir_p!(compile_path)
    file = Path.join(compile_path, "fixture.ex")
    File.write!(file, source)

    compiled = Code.compile_file(file)

    Enum.each(compiled, fn {module, bytes} ->
      beam_path = Path.join(compile_path, Atom.to_string(module) <> ".beam")
      File.write!(beam_path, bytes)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(beam_path), bytes)
    end)

    entry = String.to_existing_atom("Elixir." <> entry_name)
    block_module = String.to_existing_atom("Elixir." <> entry_name <> ".Blocks.Stone")

    %{entry: entry, block_module: block_module, compile_path: compile_path}
  end

  defp temp_path(prefix),
    do: Path.join(System.tmp_dir!(), "wyram-#{prefix}-#{System.unique_integer([:positive])}")
end
