defmodule Wyram.Plugin.Compiler do
  @moduledoc "Build-time linker and deterministic catalog artifact writer."

  alias Wyram.Plugin.Compiler.{Beam, DependencyArtifacts}

  alias Wyram.Plugin.{
    CatalogCollector,
    ContentCompiler,
    Diagnostic,
    GameCompiler,
    Linker,
    ModuleName,
    SourceLocation
  }

  @magic :wyram_plugin_catalog
  @max_catalog_bytes 16 * 1024 * 1024
  @max_compile_data_bytes 16 * 1024 * 1024

  @doc "Returns the deterministic catalog path for the current Mix application."
  def catalog_path do
    Path.join([Mix.Project.app_path(), "priv", "wyram", "catalog.term"])
  end

  @doc "Compiles one plugin entry against supplied compiled dependency artifacts."
  def compile_entry(entry, options \\ [])

  def compile_entry(entry, options) when is_atom(entry) and is_list(options) do
    path = Keyword.get(options, :catalog_path, catalog_path())
    File.rm(path)

    with {:ok, metadata} <- plugin_metadata(entry),
         {:ok, dependency_artifacts} <- dependency_artifacts(options),
         metadata <- %{metadata | dependencies: dependency_artifacts |> Map.keys() |> Enum.sort()},
         {:ok, modules, module_hashes} <-
           owned_modules(Keyword.get(options, :compile_path, Mix.Project.compile_path())),
         :ok <- validate_module_namespace(modules, entry),
         {:ok, collected} <- CatalogCollector.collect(metadata, modules),
         declarations <- collected.blocks,
         metadata <- %{metadata | declaration_modules: collected.modules},
         :ok <- validate_owned_modules(entry, metadata, declarations, modules),
         {:ok, dependency_interfaces} <-
           DependencyArtifacts.inputs(metadata, dependency_artifacts),
         plugin <-
           Map.merge(metadata, %{
             entry: entry,
             declarations: declarations,
             modules: modules,
             module_hashes: module_hashes
           }),
         {:ok, linked} <-
           Linker.link_plugin(
             plugin,
             declarations,
             dependency_interfaces,
             Keyword.get(options, :link_options, [])
           ),
         {:ok, content} <-
           ContentCompiler.compile(
             plugin,
             collected.content,
             linked.catalog,
             dependency_interfaces
           ),
         {:ok, game_config} <-
           GameCompiler.compile(
             plugin,
             Map.put(linked.catalog, :content, content),
             dependency_interfaces
           ),
         {:ok, artifact} <- artifact(plugin, linked, dependency_interfaces, game_config, content),
         :ok <- write_artifact(path, artifact) do
      {:ok, artifact}
    else
      {:error, %Diagnostic{} = diagnostic} ->
        {:error, [diagnostic]}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, diagnostics}

      {:error, reason} ->
        {:error,
         [
           Diagnostic.new!(
             :plugin_compile_failed,
             "plugin compilation failed: #{inspect(reason)}",
             source(entry)
           )
         ]}
    end
  rescue
    error ->
      File.rm(Keyword.get(options, :catalog_path, catalog_path()))
      {:error, [Diagnostic.new!(:plugin_compile_failed, Exception.message(error), source(entry))]}
  end

  def compile_entry(_entry, _options) do
    {:error,
     [
       Diagnostic.new!(
         :invalid_plugin_entry,
         "plugin entry must be a compiled module",
         source(nil)
       )
     ]}
  end

  defp dependency_artifacts(options) do
    case Keyword.get(options, :dependencies, :discover) do
      :discover -> DependencyArtifacts.project_dependencies()
      dependencies when is_map(dependencies) -> {:ok, dependencies}
      _ -> {:error, :invalid_dependency_interfaces}
    end
  end

  @doc "Computes the shared deterministic interface fingerprint."
  def fingerprint(interface) do
    :crypto.hash(:sha256, :erlang.term_to_binary(interface, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "Finds and validates compiled catalogs for every explicitly required Mix dependency."
  def discover_dependency_interfaces(metadata) when is_map(metadata) do
    DependencyArtifacts.discover(metadata)
  end

  defp plugin_metadata(entry) do
    with :ok <- ensure_plugin_entry(entry) do
      metadata = entry.__wyram_plugin__()

      if valid_plugin_metadata?(metadata) do
        {:ok, Map.put(metadata, :entry, entry)}
      else
        {:error,
         Diagnostic.new!(
           :invalid_plugin_metadata,
           "entry module returned invalid plugin metadata",
           source(entry)
         )}
      end
    end
  end

  defp ensure_plugin_entry(entry) do
    if Code.ensure_loaded?(entry) and function_exported?(entry, :__wyram_plugin__, 0) do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :missing_plugin_metadata,
         "entry module does not export __wyram_plugin__/0",
         source(entry)
       )}
    end
  end

  defp valid_plugin_metadata?(metadata) do
    is_map(metadata) and valid_plugin_metadata_keys?(metadata) and
      valid_plugin_identity?(metadata) and valid_plugin_members?(metadata)
  end

  defp valid_plugin_metadata_keys?(metadata) do
    Map.keys(metadata) -- [:id, :dependencies, :declaration_modules, :catalogs, :providers, :game] ==
      []
  end

  defp valid_plugin_identity?(metadata) do
    is_binary(Map.get(metadata, :id)) and is_list(Map.get(metadata, :dependencies)) and
      (is_nil(Map.get(metadata, :game)) or ModuleName.valid?(metadata.game))
  end

  defp valid_plugin_members?(metadata) do
    is_list(Map.get(metadata, :declaration_modules)) and is_list(Map.get(metadata, :providers)) and
      Enum.all?(metadata.declaration_modules, &ModuleName.valid?/1) and
      Enum.all?(metadata.providers, &ModuleName.valid?/1)
  end

  defp validate_owned_modules(entry, metadata, declarations, owned_modules) do
    declaration_modules = Enum.map(declarations, &Map.get(&1, :module))

    expected =
      Enum.uniq([
        entry
        | metadata.declaration_modules ++
            metadata.providers ++ declaration_modules ++ List.wrap(metadata.game)
      ])

    missing = Enum.reject(expected, &(&1 in owned_modules))

    if missing == [] do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :module_ownership_mismatch,
         "plugin metadata references modules outside its compiled application: #{inspect(missing)}",
         source(entry)
       )}
    end
  end

  defp validate_module_namespace(modules, entry) do
    invalid = Enum.reject(modules, &ModuleName.valid?/1)

    if invalid == [] do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :invalid_plugin_module_namespace,
         "plugin-owned modules must have valid Elixir names: #{inspect(invalid)}",
         source(entry)
       )}
    end
  end

  defp owned_modules(compile_path) do
    with {:ok, paths} <- beam_paths(compile_path),
         {:ok, modules, hashes} <- collect_owned_modules(paths) do
      {:ok, Enum.sort(modules), hashes}
    end
  end

  defp beam_paths(compile_path) do
    case File.ls(compile_path) do
      {:ok, names} ->
        paths =
          names
          |> Enum.filter(&String.ends_with?(&1, ".beam"))
          |> Enum.map(&Path.join(compile_path, &1))
          |> Enum.sort()

        {:ok, paths}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_owned_modules(paths) do
    Enum.reduce_while(paths, {:ok, [], %{}}, fn path, {:ok, modules, hashes} ->
      case owned_module(path) do
        {:ok, module, hash} ->
          {:cont, {:ok, [module | modules], Map.put(hashes, Atom.to_string(module), hash)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp owned_module(path) do
    case :beam_lib.info(String.to_charlist(path)) do
      info when is_list(info) ->
        module = info[:module]

        with {:ok, bytes} <- File.read(path),
             {:ok, canonical} <- Beam.canonical_bytes(bytes),
             :ok <- File.write(path, canonical, [:binary]) do
          {:ok, module, sha256(canonical)}
        end

      error ->
        {:error, error}
    end
  end

  defp artifact(plugin, linked, dependency_interfaces, game_config, content) do
    id = plugin.id
    interface = linked.interface
    catalog = linked.catalog

    serialized_catalog = %{
      id: id,
      dependencies: Enum.sort(plugin.dependencies),
      blocks: Enum.map(catalog.blocks, &serialize_block/1),
      content: content,
      game: game_config
    }

    dependency_fingerprints =
      Map.new(dependency_interfaces, fn {dep_id, %{interface_fingerprint: dependency_fingerprint}} ->
        {dep_id, dependency_fingerprint}
      end)

    plugin_payload = %{
      id: id,
      entry: Atom.to_string(plugin.entry),
      dependencies: Enum.sort(plugin.dependencies),
      owned_modules: Enum.map(plugin.modules, &Atom.to_string/1),
      provider_modules: Enum.map(plugin.providers, &Atom.to_string/1),
      game: maybe_module_name(plugin.game)
    }

    interface =
      interface
      |> Map.update!(:plugins, fn [owner | rest] ->
        [Map.put(owner, :compiled_content, content) | rest]
      end)
      |> Map.drop([:symbols])
      |> serialize_interface()
      |> Map.put(:compiled_blocks, serialized_catalog.blocks)
      |> Map.put(:compiled_game, serialized_catalog.game)
      |> Map.put(:compiled_content, serialized_catalog.content)

    with :ok <- validate_export_size(interface) do
      payload = %{
        magic: @magic,
        plugin: plugin_payload,
        catalog: serialized_catalog,
        interface: interface,
        interface_fingerprint: fingerprint(interface),
        dependency_interfaces: dependency_fingerprints
      }

      with :ok <- validate_export_size(payload), do: {:ok, payload}
    end
  end

  defp serialize_block(block) do
    %{
      id: block.id,
      plugin_id: block.plugin_id,
      local_id: block.local_id,
      module: Atom.to_string(block.module),
      kind: block.kind,
      descriptor: block.descriptor,
      source: serialize_source(block.source)
    }
  end

  defp serialize_source(source) do
    %{
      file: source.file,
      line: source.line,
      column: source.column,
      module: maybe_module_name(source.module)
    }
  end

  defp serialize_interface(interface) do
    compile_data =
      %{declarations: interface.declarations, plugins: interface.plugins}
      |> :erlang.term_to_binary([:deterministic])

    interface
    |> Map.drop([:plugins])
    |> Map.update!(
      :declarations,
      &Enum.map(&1, fn declaration -> %{declaration | entries: []} end)
    )
    |> Map.update!(:entry, &Atom.to_string/1)
    |> Map.update!(
      :modules,
      &Enum.map(&1, fn module -> if is_atom(module), do: Atom.to_string(module), else: module end)
    )
    |> Map.update!(:providers, &Enum.map(&1, fn module -> Atom.to_string(module) end))
    |> Map.update!(:game, &maybe_module_name/1)
    |> Map.put(:compile_data, compile_data)
  end

  defp validate_export_size(%{compile_data: bytes}) when is_binary(bytes) do
    if byte_size(bytes) <= @max_compile_data_bytes,
      do: :ok,
      else: {:error, oversized_catalog()}
  end

  defp validate_export_size(payload) when is_map(payload) do
    if byte_size(:erlang.term_to_binary(payload, [:deterministic])) <= @max_catalog_bytes,
      do: :ok,
      else: {:error, oversized_catalog()}
  end

  defp oversized_catalog do
    Diagnostic.new!(
      :plugin_catalog_too_large,
      "compiled plugin catalog exceeds the 16 MiB build-time limit",
      source(nil)
    )
  end

  defp maybe_module_name(nil), do: nil
  defp maybe_module_name(module) when is_atom(module), do: Atom.to_string(module)

  defp write_artifact(path, artifact) do
    bytes = :erlang.term_to_binary(artifact, [:deterministic])

    if byte_size(bytes) <= @max_catalog_bytes do
      File.mkdir_p!(Path.dirname(path))
      temporary = path <> ".tmp"

      case File.write(temporary, bytes, [:binary]) do
        :ok -> File.rename(temporary, path)
        error -> error
      end
    else
      {:error, oversized_catalog()}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source(entry) when is_atom(entry),
    do: %SourceLocation{file: "mix.exs", line: 1, module: entry}
end
