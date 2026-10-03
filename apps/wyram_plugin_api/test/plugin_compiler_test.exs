defmodule Wyram.Plugin.CompilerTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.WyramPrepare
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
             material: %{color: {12, 34, 56}, mode: :opaque}
           }

    assert Enum.sort(Map.keys(first.interface.module_hashes)) == first.plugin.owned_modules
    assert first.interface.modules == first.plugin.owned_modules
    assert first.interface_fingerprint == Compiler.fingerprint(first.interface)
    refute Map.has_key?(hd(first.catalog.blocks), :entries)
    assert first.interface.compiled_blocks == first.catalog.blocks
    assert Enum.all?(first.interface.declarations, &(&1.entries == []))
    refute Map.has_key?(first.interface, :plugins)

    compile_data = :erlang.binary_to_term(first.interface.compile_data, [:safe])
    assert Map.keys(compile_data) |> Enum.sort() == [:declarations, :plugins]

    assert Enum.map(compile_data.declarations, &%{&1 | entries: []}) ==
             first.interface.declarations

    assert hd(compile_data.declarations).entries != []
    assert is_list(compile_data.plugins) and compile_data.plugins != []
    assert first.interface.compiled_game == first.catalog.game

    refute Compiler.fingerprint(Map.put(first.interface, :compiled_game, :tampered)) ==
             first.interface_fingerprint

    changed_descriptor =
      put_in(
        first.interface,
        [:compiled_blocks, Access.at(0), :descriptor, :material, :color],
        {1, 2, 3}
      )

    refute Compiler.fingerprint(changed_descriptor) == first.interface_fingerprint

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

    assert {:ok, []} = WyramPrepare.run([])
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

  test "compiler accepts developer-chosen plugin module namespaces" do
    fixture =
      compile_fixture("bad_namespace", "compiler-bad-namespace", [], nil,
        prefix: "Wyram.Plugin.CompilerFixtureBadNamespace"
      )

    path = temp_path("bad-namespace")

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(fixture.compile_path)
    end)

    assert {:ok, artifact} =
             Compiler.compile_entry(fixture.entry,
               catalog_path: path,
               compile_path: fixture.compile_path
             )

    assert artifact.plugin.id == "compiler-bad-namespace"
    assert File.exists?(path)
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

    invalid_compile_data =
      :erlang.term_to_binary(%{declarations: [], plugins: []}, [:deterministic])

    invalid_interface = Map.put(base_artifact.interface, :compile_data, invalid_compile_data)

    assert {:error, [diagnostic]} =
             Compiler.compile_entry(addon.entry,
               catalog_path: addon_path,
               compile_path: addon.compile_path,
               dependencies: %{
                 "compiler-base" => dependency_artifact(invalid_interface)
               }
             )

    assert diagnostic.code == :invalid_dependency_compile_data

    original_compile_data =
      :erlang.binary_to_term(base_artifact.interface.compile_data, [:safe])

    [owner | dependencies] = original_compile_data.plugins

    inconsistent_compile_data =
      original_compile_data
      |> Map.put(:plugins, [Map.put(owner, :declarations, []) | dependencies])
      |> :erlang.term_to_binary([:deterministic])

    inconsistent_interface =
      Map.put(base_artifact.interface, :compile_data, inconsistent_compile_data)

    assert {:error, [owner_diagnostic]} =
             Compiler.compile_entry(addon.entry,
               catalog_path: addon_path,
               compile_path: addon.compile_path,
               dependencies: %{
                 "compiler-base" => dependency_artifact(inconsistent_interface)
               }
             )

    assert owner_diagnostic.code == :invalid_dependency_compile_data

    compressed_interface =
      Map.put(
        base_artifact.interface,
        :compile_data,
        :erlang.term_to_binary(%{declarations: [], plugins: []}, [:compressed])
      )

    assert {:error, [compressed_diagnostic]} =
             Compiler.compile_entry(addon.entry,
               catalog_path: addon_path,
               compile_path: addon.compile_path,
               dependencies: %{
                 "compiler-base" => dependency_artifact(compressed_interface)
               }
             )

    assert compressed_diagnostic.code == :invalid_dependency_compile_data

    oversized_interface =
      Map.put(base_artifact.interface, :compile_data, :binary.copy(<<0>>, 16 * 1024 * 1024 + 1))

    assert {:error, [oversized_diagnostic]} =
             Compiler.compile_entry(addon.entry,
               catalog_path: addon_path,
               compile_path: addon.compile_path,
               dependencies: %{
                 "compiler-base" => dependency_artifact(oversized_interface)
               }
             )

    assert oversized_diagnostic.code == :invalid_dependency_compile_data
  end

  defp dependency_artifact(interface),
    do: %{interface: interface, interface_fingerprint: Compiler.fingerprint(interface)}

  defp compile_fixture(suffix, plugin_id, _dependencies, template_module, options \\ []) do
    module_prefix =
      Keyword.get(options, :prefix, "WyramMods.CompilerFixture#{String.capitalize(suffix)}")

    entry_name = "#{module_prefix}.Entry"
    blocks_name = "#{module_prefix}.Blocks"
    body = if template_module, do: "template(#{inspect(template_module)})", else: ""
    override = if template_module, do: ", override: true", else: ""

    source = """
    defmodule #{entry_name} do
      use Wyram.Plugin
      catalog #{blocks_name}
    end

    defmodule #{blocks_name} do
      use Wyram.Plugin.Catalog, kind: :block
      defblock Stone, id: "stone" do
        #{body}
        capability %Wyram.Capability.Material{color: {12, 34, 56}, mode: :opaque}#{override}
      end
    end
    """

    compile_path = temp_path("beams")
    File.mkdir_p!(compile_path)
    file = Path.join(compile_path, "fixture.ex")
    File.write!(file, source)

    compiled =
      Wyram.PluginTestProject.with_app(
        String.to_atom(plugin_id),
        Module.concat([entry_name]),
        fn ->
          Code.compile_file(file)
        end
      )

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
