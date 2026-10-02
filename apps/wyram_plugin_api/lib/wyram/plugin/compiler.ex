defmodule Wyram.Plugin.Compiler do
  @moduledoc "Build-time linker and deterministic catalog artifact writer."

  alias Wyram.Plugin.Compiler.DependencyArtifacts
  alias Wyram.Plugin.{Diagnostic, Linker, ModuleName, SourceLocation}

  @magic :wyram_plugin_catalog

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
         {:ok, declarations} <- collect_declarations(entry, metadata),
         {:ok, modules, module_hashes} <-
           owned_modules(Keyword.get(options, :compile_path, Mix.Project.compile_path())),
         :ok <- validate_module_namespace(modules, entry),
         :ok <- validate_owned_modules(entry, metadata, declarations, modules),
         {:ok, dependency_interfaces} <-
           DependencyArtifacts.inputs(metadata, Keyword.get(options, :dependencies, :discover)),
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
         {:ok, artifact} <-
           artifact(plugin, linked, dependency_interfaces, Keyword.get(options, :game_config)),
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
    Map.keys(metadata) -- [:id, :dependencies, :declaration_modules, :providers, :game] == []
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

  defp collect_declarations(entry, metadata) do
    Enum.reduce_while(metadata.declaration_modules, {:ok, []}, fn module, {:ok, declarations} ->
      case declaration_values(module, entry) do
        {:ok, values} -> {:cont, {:ok, declarations ++ values}}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp declaration_values(module, entry) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__wyram_declarations__, 0) do
      case module.__wyram_declarations__() do
        values when is_list(values) -> {:ok, values}
        _ -> {:error, invalid_contributor(entry, module)}
      end
    else
      {:error, missing_contributor(entry, module)}
    end
  end

  defp invalid_contributor(entry, module) do
    Diagnostic.new!(
      :invalid_declaration_contributor,
      "#{inspect(module)} returned an invalid declaration list",
      source(entry)
    )
  end

  defp missing_contributor(entry, module) do
    Diagnostic.new!(
      :missing_declaration_contributor,
      "#{inspect(module)} does not export __wyram_declarations__/0",
      source(entry)
    )
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
    invalid = Enum.reject(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.WyramMods."))

    if invalid == [] do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :invalid_plugin_module_namespace,
         "plugin-owned modules must use the WyramMods namespace: #{inspect(invalid)}",
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

        case File.read(path) do
          {:ok, bytes} -> {:ok, module, sha256(bytes)}
          {:error, reason} -> {:error, reason}
        end

      error ->
        {:error, error}
    end
  end

  defp artifact(plugin, linked, dependency_interfaces, game_config) do
    id = plugin.id
    interface = linked.interface
    catalog = linked.catalog

    serialized_catalog = %{
      id: id,
      dependencies: Enum.sort(plugin.dependencies),
      blocks: Enum.map(catalog.blocks, &serialize_block/1),
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
      |> Map.drop([:symbols])
      |> serialize_interface()
      |> Map.put(:compiled_blocks, serialized_catalog.blocks)

    payload = %{
      magic: @magic,
      plugin: plugin_payload,
      catalog: serialized_catalog,
      interface: interface,
      interface_fingerprint: fingerprint(interface),
      dependency_interfaces: dependency_fingerprints
    }

    {:ok, payload}
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
    interface
    |> Map.update!(:entry, &Atom.to_string/1)
    |> Map.update!(
      :modules,
      &Enum.map(&1, fn module -> if is_atom(module), do: Atom.to_string(module), else: module end)
    )
    |> Map.update!(:providers, &Enum.map(&1, fn module -> Atom.to_string(module) end))
    |> Map.update!(:game, &maybe_module_name/1)
  end

  defp maybe_module_name(nil), do: nil
  defp maybe_module_name(module) when is_atom(module), do: Atom.to_string(module)

  defp write_artifact(path, artifact) do
    bytes = :erlang.term_to_binary(artifact, [:deterministic])
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp"

    case File.write(temporary, bytes, [:binary]) do
      :ok -> File.rename(temporary, path)
      error -> error
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source(entry) when is_atom(entry),
    do: %SourceLocation{file: "mix.exs", line: 1, module: entry}
end
