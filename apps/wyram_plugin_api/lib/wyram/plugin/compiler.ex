defmodule Wyram.Plugin.Compiler do
  @moduledoc "Build-time linker and deterministic catalog artifact writer."

  alias Wyram.Plugin.{Diagnostic, Linker, SourceLocation}

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
         :ok <- validate_owned_modules(entry, metadata, declarations, modules),
         {:ok, dependency_interfaces} <-
           dependency_inputs(metadata, Keyword.get(options, :dependencies, :discover)),
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
    with {:ok, artifacts} <- dependency_artifacts(),
         :ok <- unique_dependency_ids(artifacts),
         {:ok, required} <-
           required_dependency_map(Map.get(metadata, :dependencies, []), artifacts) do
      {:ok, required}
    end
  end

  defp plugin_metadata(entry) do
    unless Code.ensure_loaded?(entry) and function_exported?(entry, :__wyram_plugin__, 0),
      do:
        throw(
          {:diagnostic,
           Diagnostic.new!(
             :missing_plugin_metadata,
             "entry module does not export __wyram_plugin__/0",
             source(entry)
           )}
        )

    metadata = apply(entry, :__wyram_plugin__, [])

    if is_map(metadata) and
         Map.keys(metadata) -- [:id, :dependencies, :declaration_modules, :providers, :game] == [] and
         is_binary(Map.get(metadata, :id)) and
         is_list(Map.get(metadata, :dependencies)) and
         is_list(Map.get(metadata, :declaration_modules)) and
         is_list(Map.get(metadata, :providers)) and
         Enum.all?(metadata.declaration_modules, &Wyram.Plugin.ModuleName.valid?/1) and
         Enum.all?(metadata.providers, &Wyram.Plugin.ModuleName.valid?/1) and
         (is_nil(Map.get(metadata, :game)) or Wyram.Plugin.ModuleName.valid?(metadata.game)) do
      {:ok, Map.put(metadata, :entry, entry)}
    else
      {:error,
       Diagnostic.new!(
         :invalid_plugin_metadata,
         "entry module returned invalid plugin metadata",
         source(entry)
       )}
    end
  catch
    {:diagnostic, diagnostic} -> {:error, diagnostic}
  end

  defp collect_declarations(entry, metadata) do
    result =
      Enum.reduce_while(metadata.declaration_modules, {:ok, []}, fn module, {:ok, declarations} ->
        if Code.ensure_loaded?(module) and function_exported?(module, :__wyram_declarations__, 0) do
          case apply(module, :__wyram_declarations__, []) do
            values when is_list(values) ->
              {:cont, {:ok, declarations ++ values}}

            _ ->
              {:halt,
               {:error,
                Diagnostic.new!(
                  :invalid_declaration_contributor,
                  "#{inspect(module)} returned an invalid declaration list",
                  source(entry)
                )}}
          end
        else
          {:halt,
           {:error,
            Diagnostic.new!(
              :missing_declaration_contributor,
              "#{inspect(module)} does not export __wyram_declarations__/0",
              source(entry)
            )}}
        end
      end)

    result
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

  defp dependency_inputs(metadata, dependencies) when is_map(dependencies) do
    required = Map.get(metadata, :dependencies, [])

    Enum.reduce_while(required, {:ok, %{}}, fn id, {:ok, acc} ->
      case Map.fetch(dependencies, id) do
        {:ok, %{interface: interface, interface_fingerprint: expected_fingerprint}} ->
          if fingerprint(interface) == expected_fingerprint do
            {:cont,
             {:ok,
              Map.put(acc, id, %{plugin: interface, interface_fingerprint: expected_fingerprint})}}
          else
            {:halt,
             {:error,
              Diagnostic.new!(
                :stale_dependency_interface,
                "dependency #{inspect(id)} interface fingerprint is invalid",
                source(nil)
              )}}
          end

        :error ->
          {:halt,
           {:error,
            Diagnostic.new!(
              :missing_dependency_interface,
              "required dependency #{inspect(id)} has no compiled interface",
              source(nil)
            )}}
      end
    end)
  end

  defp dependency_inputs(metadata, :discover),
    do: discover_dependency_interfaces(metadata)

  defp dependency_inputs(_metadata, _),
    do:
      {:error,
       Diagnostic.new!(
         :invalid_dependency_interfaces,
         "dependencies must be supplied as a map",
         source(nil)
       )}

  defp dependency_artifacts do
    Mix.Project.deps_paths()
    |> Map.keys()
    |> Enum.reduce_while({:ok, []}, fn app, {:ok, artifacts} ->
      case load_dependency_artifact(app) do
        :none -> {:cont, {:ok, artifacts}}
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp load_dependency_artifact(app) do
    case :code.lib_dir(app) do
      app_dir when is_list(app_dir) ->
        case :application.load(app) do
          :ok -> :ok
          {:error, {:already_loaded, ^app}} -> :ok
          {:error, reason} -> throw({:dependency_load_error, app, reason})
        end

        app_modules = Application.spec(app, :modules) || []
        Enum.each(app_modules, &Code.ensure_loaded/1)
        catalog_path = Path.join([List.to_string(app_dir), "priv", "wyram", "catalog.term"])

        if File.exists?(catalog_path) do
          with {:ok, bytes} <- File.read(catalog_path),
               {:ok, artifact} <- decode_artifact(bytes),
               :ok <- validate_artifact(artifact, app_modules) do
            {:ok, artifact}
          else
            {:error, %Diagnostic{} = diagnostic} ->
              {:error, diagnostic}

            {:error, reason} ->
              {:error,
               Diagnostic.new!(
                 :invalid_dependency_catalog,
                 "dependency #{inspect(app)} catalog is invalid: #{inspect(reason)}",
                 source(nil)
               )}
          end
        else
          :none
        end

      _ ->
        :none
    end
  catch
    {:dependency_load_error, app, reason} ->
      {:error,
       Diagnostic.new!(
         :dependency_load_failed,
         "cannot load dependency #{inspect(app)} metadata: #{inspect(reason)}",
         source(nil)
       )}
  end

  defp decode_artifact(bytes) do
    try do
      {:ok, :erlang.binary_to_term(bytes, [:safe])}
    rescue
      error -> {:error, error}
    end
  end

  defp validate_artifact(
         %{
           magic: @magic,
           plugin: %{id: id, owned_modules: owned, dependencies: dependencies},
           catalog: %{id: id, dependencies: dependencies, blocks: blocks},
           interface:
             %{id: id, modules: modules, dependencies: dependencies, module_hashes: hashes} =
               interface,
           interface_fingerprint: expected
         },
         app_modules
       )
       when is_binary(expected) and is_list(owned) and is_list(modules) and is_map(hashes) and
              is_list(blocks) do
    app_modules_by_name = Map.new(app_modules, &{Atom.to_string(&1), &1})

    actual_hashes =
      Enum.reduce_while(owned, {:ok, %{}}, fn name, {:ok, acc} ->
        with module when is_atom(module) <- Map.get(app_modules_by_name, name),
             beam when is_list(beam) <- :code.which(module),
             {:ok, bytes} <- File.read(List.to_string(beam)) do
          {:cont, {:ok, Map.put(acc, name, sha256(bytes))}}
        else
          _ -> {:halt, {:error, name}}
        end
      end)

    cond do
      owned != modules or Enum.sort(owned) != owned ->
        {:error,
         Diagnostic.new!(
           :invalid_dependency_modules,
           "dependency module ownership list is inconsistent",
           source(nil)
         )}

      match?({:error, _}, actual_hashes) ->
        {:error,
         Diagnostic.new!(
           :dependency_module_missing,
           "dependency package is missing a manifest-listed BEAM module",
           source(nil)
         )}

      actual_hashes != {:ok, hashes} ->
        {:error,
         Diagnostic.new!(
           :dependency_module_hash_mismatch,
           "dependency BEAM hashes do not match its compiled interface",
           source(nil)
         )}

      fingerprint(interface) != expected ->
        {:error,
         Diagnostic.new!(
           :stale_dependency_interface,
           "dependency interface fingerprint does not match its catalog",
           source(nil)
         )}

      true ->
        :ok
    end
  end

  defp validate_artifact(_, _app_modules),
    do:
      {:error,
       Diagnostic.new!(
         :invalid_dependency_catalog,
         "dependency artifact has an invalid shape",
         source(nil)
       )}

  defp unique_dependency_ids(artifacts) do
    ids = Enum.map(artifacts, & &1.plugin.id)

    case duplicates(ids) do
      [] ->
        :ok

      [id | _] ->
        {:error,
         Diagnostic.new!(
           :duplicate_dependency_plugin_id,
           "multiple Mix dependencies provide plugin ID #{inspect(id)}",
           source(nil)
         )}
    end
  end

  defp required_dependency_map(required_ids, artifacts) when is_list(required_ids) do
    by_id = Map.new(artifacts, &{&1.plugin.id, &1})

    Enum.reduce_while(required_ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case Map.fetch(by_id, id) do
        {:ok, artifact} ->
          {:cont,
           {:ok,
            Map.put(acc, id, %{
              interface: artifact.interface,
              interface_fingerprint: artifact.interface_fingerprint
            })}}

        :error ->
          {:halt,
           {:error,
            Diagnostic.new!(
              :missing_dependency_interface,
              "required plugin dependency #{inspect(id)} has no compiled Mix dependency catalog",
              source(nil)
            )}}
      end
    end)
  end

  defp required_dependency_map(_required, _artifacts),
    do:
      {:error,
       Diagnostic.new!(
         :invalid_dependency_list,
         "plugin dependencies must be a list",
         source(nil)
       )}

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp owned_modules(compile_path) do
    beam_paths =
      case File.ls(compile_path) do
        {:ok, names} ->
          names
          |> Enum.filter(&String.ends_with?(&1, ".beam"))
          |> Enum.map(&Path.join(compile_path, &1))
          |> Enum.sort()

        {:error, reason} ->
          throw({:compile_path_error, reason})
      end

    beam_paths
    |> Enum.reduce_while({:ok, [], %{}}, fn path, {:ok, modules, hashes} ->
      case :beam_lib.info(String.to_charlist(path)) do
        info when is_list(info) ->
          module = info[:module]

          case File.read(path) do
            {:ok, bytes} ->
              {:cont,
               {:ok, [module | modules], Map.put(hashes, Atom.to_string(module), sha256(bytes))}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        error ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, modules, hashes} -> {:ok, Enum.sort(modules), hashes}
      error -> error
    end
  catch
    {:compile_path_error, reason} -> {:error, reason}
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

    with :ok <- File.write(temporary, bytes, [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source(entry) when is_atom(entry),
    do: %SourceLocation{file: "mix.exs", line: 1, module: entry}

  defp source(_), do: %SourceLocation{file: "mix.exs", line: 1}
end
