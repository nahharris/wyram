defmodule Wyram.Engine.PluginManagerArtifactTest do
  use ExUnit.Case, async: true

  alias Wyram.Engine.{PluginCatalog, PluginManager}
  alias Wyram.Plugin.{Declaration, SourceLocation}

  test "reads a BEAM module identity without loading the module" do
    path = :code.which(Wyram.Engine.Application) |> List.to_string()
    assert {:ok, bytes} = File.read(path)
    assert {:ok, "Elixir.Wyram.Engine.Application"} = PluginManager.beam_module_name(bytes)
  end

  test "rejects malformed or non-BEAM binaries when inspecting identity" do
    assert {:error, :invalid_beam} = PluginManager.beam_module_name(<<0, 1, 2>>)
    assert {:error, :invalid_beam} = PluginManager.beam_module_name("FOR1" <> <<0::32>> <> "BEAM")
  end

  test "preloads trusted catalog schema atoms before safe decoding in a fresh VM" do
    root = Path.expand("../../..", __DIR__)

    directory =
      Path.join(System.tmp_dir!(), "wyram-safe-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    on_exit(fn -> File.rm_rf(directory) end)

    artifact_path = Path.join(directory, "catalog.term")
    marker_path = Path.join(directory, "compile-data-atoms.txt")
    marker_names = ["opaque_compile_data_alpha", "opaque_compile_data_beta"]
    File.write!(marker_path, Enum.join(marker_names, "\n"))

    compile_data =
      Base.decode64!(
        "g2gCdxlvcGFxdWVfY29tcGlsZV9kYXRhX2FscGhhdxhvcGFxdWVfY29tcGlsZV9kYXRhX2JldGE="
      )

    artifact =
      :erlang.term_to_binary(%{
        interface: %{compiled_blocks: [], compile_data: compile_data, compiled_game: nil}
      })

    File.write!(artifact_path, artifact)

    script_path = Path.join(directory, "safe-decode.exs")

    File.write!(script_path, """
    :ok = Wyram.Engine.PluginManager.ensure_catalog_schema_modules()
    decoded = :erlang.binary_to_term(File.read!(System.fetch_env!(\"WYRAM_CATALOG_TEST_TERM\")), [:safe])
    true = is_binary(decoded.interface.compile_data)
    missing_atoms =
      File.read!(System.fetch_env!(\"WYRAM_CATALOG_TEST_MARKERS\"))
      |> String.split("\\n", trim: true)
      |> Enum.filter(fn name ->
        try do
          String.to_existing_atom(name)
          false
        rescue
          ArgumentError -> true
        end
      end)
    true = length(missing_atoms) == 2
    IO.puts(\"safe catalog decode passed\")
    """)

    mix = System.find_executable("mix")
    assert is_binary(mix)
    command = "mix run --no-start --no-compile #{script_path}"

    {output, status} =
      System.cmd("cmd.exe", ["/d", "/c", command],
        cd: root,
        env: [
          {"MIX_ENV", Atom.to_string(Mix.env())},
          {"WYRAM_CATALOG_TEST_TERM", artifact_path},
          {"WYRAM_CATALOG_TEST_MARKERS", marker_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "safe catalog decode passed"
  end

  test "safely decodes dependency summaries without interning opaque compiler atoms" do
    for order <- [[:addon, :terrain], [:terrain, :addon]] do
      directory =
        Path.join(
          System.tmp_dir!(),
          "wyram-opaque-catalog-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf(directory) end)
      marker_names = write_catalog_fixture_packages(directory, order)

      {output, status} = run_plugin_manager_in_fresh_vm(directory, marker_names)

      assert status == 0, output
      assert output =~ "catalogs decoded before game selection"
      assert output =~ "opaque compile_data atoms remained unknown"
    end
  end

  test "checks each verified BEAM hash against the compiled interface before loading" do
    name = "Elixir.Wyram.Engine.Application"
    path = :code.which(Wyram.Engine.Application) |> List.to_string()
    assert {:ok, bytes} = File.read(path)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    manifest = %{"modules" => [name]}
    catalog = %{interface: %{module_hashes: %{name => hash}}}
    contents = [{String.to_charlist("ebin/#{name}.beam"), bytes}]

    assert :ok = PluginManager.verify_beam_modules(manifest, catalog, contents)

    stale = put_in(catalog.interface.module_hashes[name], String.duplicate("0", 64))

    assert {:error, {:module_hash_mismatch, ^name}} =
             PluginManager.verify_beam_modules(manifest, stale, contents)
  end

  test "rejects a real ZIP whose expanded files exceed the package budget" do
    path =
      Path.join(System.tmp_dir!(), "wyram-expanded-#{System.unique_integer([:positive])}.zip")

    on_exit(fn -> File.rm(path) end)
    large = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
    assert {:ok, _} = :zip.create(String.to_charlist(path), [{~c"large.bin", large}])

    assert {:error, :invalid_or_oversized_archive} = PluginManager.validate_archive(path)
  end

  defp write_catalog_fixture_packages(directory, order) do
    {terrain_module, terrain_beam} = compile_fixture_module("Terrain")
    {addon_module, addon_beam} = compile_fixture_module("Addon")
    marker_names = ["opaque_compile_data_alpha", "opaque_compile_data_beta"]

    compile_data =
      Base.decode64!(
        "g2gCdxlvcGFxdWVfY29tcGlsZV9kYXRhX2FscGhhdxhvcGFxdWVfY29tcGlsZV9kYXRhX2JldGE="
      )

    terrain_interface =
      fixture_interface("terrain", terrain_module, [], terrain_beam, compile_data)

    addon_interface =
      fixture_interface("addon", addon_module, ["terrain"], addon_beam, compile_data)

    write_catalog_fixture_package(
      directory,
      fixture_filename(order, :terrain),
      "terrain",
      terrain_module,
      terrain_beam,
      terrain_interface,
      %{}
    )

    write_catalog_fixture_package(
      directory,
      fixture_filename(order, :addon),
      "addon",
      addon_module,
      addon_beam,
      addon_interface,
      %{"terrain" => PluginCatalog.interface_fingerprint(terrain_interface)}
    )

    marker_names
  end

  defp fixture_filename([:addon, :terrain], :addon), do: "a-addon.wyrplug"
  defp fixture_filename([:addon, :terrain], :terrain), do: "z-terrain.wyrplug"
  defp fixture_filename([:terrain, :addon], :terrain), do: "a-terrain.wyrplug"
  defp fixture_filename([:terrain, :addon], :addon), do: "z-addon.wyrplug"

  defp fixture_interface(id, module, dependencies, beam, compile_data) do
    module_name = Atom.to_string(module)

    declaration = %Declaration{
      plugin_id: id,
      local_id: nil,
      module: module,
      kind: :block,
      role: :template,
      source: %SourceLocation{file: "fixture.ex", line: 1, column: 1},
      entries: []
    }

    %{
      id: id,
      entry: module_name,
      dependencies: dependencies,
      declarations: [declaration],
      providers: [],
      modules: [module_name],
      game: nil,
      compiled_game: nil,
      compile_data: compile_data,
      compiled_blocks: [],
      module_hashes: %{module_name => sha256(beam)}
    }
  end

  defp write_catalog_fixture_package(
         directory,
         filename,
         id,
         module,
         beam,
         interface,
         dependency_interfaces
       ) do
    module_name = Atom.to_string(module)
    interface_fingerprint = PluginCatalog.interface_fingerprint(interface)
    version = Version.parse!(System.version())

    artifact = %{
      magic: :wyram_plugin_catalog,
      plugin: %{
        id: id,
        entry: module_name,
        dependencies: interface.dependencies,
        owned_modules: interface.modules,
        provider_modules: [],
        game: nil
      },
      catalog: %{id: id, dependencies: interface.dependencies, blocks: [], game: nil},
      interface: interface,
      interface_fingerprint: interface_fingerprint,
      dependency_interfaces: dependency_interfaces
    }

    artifact_bytes = :erlang.term_to_binary(artifact)

    manifest = %{
      "id" => id,
      "version" => "0.1.0",
      "otp" => System.otp_release(),
      "elixir" => "#{version.major}.#{version.minor}",
      "entry" => module_name,
      "modules" => [module_name],
      "dependencies" => interface.dependencies,
      "catalog" => "catalog.term",
      "catalog_sha256" => sha256(artifact_bytes)
    }

    files = [
      {~c"manifest.json", Jason.encode!(manifest)},
      {~c"catalog.term", artifact_bytes},
      {String.to_charlist("ebin/#{module_name}.beam"), beam}
    ]

    {:ok, _} = :zip.create(String.to_charlist(Path.join(directory, filename)), files)
  end

  defp run_plugin_manager_in_fresh_vm(directory, marker_names) do
    script_path = Path.join(directory, "startup.exs")
    marker_path = Path.join(directory, "compile-data-atoms.txt")
    File.write!(marker_path, Enum.join(marker_names, "\n"))

    File.write!(script_path, """
    Process.flag(:trap_exit, true)
    result = Wyram.Engine.PluginManager.start_link(directory: System.fetch_env!("WYRAM_CATALOG_TEST_DIRECTORY"))
    missing =
      File.read!(System.fetch_env!("WYRAM_CATALOG_TEST_MARKERS"))
      |> String.split("\\n", trim: true)
      |> Enum.filter(fn name ->
        try do
          String.to_existing_atom(name)
          false
        rescue
          ArgumentError -> true
        end
      end)

    case result do
      {:error, :missing_game_configuration} ->
        true = length(missing) == 2
        IO.puts("opaque compile_data atoms remained unknown")
        IO.puts("catalogs decoded before game selection")
      {:error, reason} -> raise "plugin startup failed: \#{inspect(reason)}"
      {:ok, pid} -> GenServer.stop(pid)
    end
    """)

    root = Path.expand("../../..", __DIR__)

    System.cmd("cmd.exe", ["/d", "/c", "mix run --no-start --no-compile #{script_path}"],
      cd: root,
      env: [
        {"MIX_ENV", Atom.to_string(Mix.env())},
        {"WYRAM_CATALOG_TEST_DIRECTORY", directory},
        {"WYRAM_CATALOG_TEST_MARKERS", marker_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp compile_fixture_module(name) do
    suffix = System.unique_integer([:positive])
    module = Module.concat([WyramMods, PluginManagerCatalogFixture, "#{name}#{suffix}"])

    quoted =
      quote do
        defmodule unquote(module) do
          def fixture, do: :ok
        end
      end

    [{^module, beam}] = Code.compile_quoted(quoted)
    {module, beam}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
