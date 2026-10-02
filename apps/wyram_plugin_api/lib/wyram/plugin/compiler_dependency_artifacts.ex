defmodule Wyram.Plugin.Compiler.DependencyArtifacts do
  @moduledoc false

  alias Wyram.Plugin.{Compiler, Diagnostic, SourceLocation}

  @magic :wyram_plugin_catalog

  def discover(metadata) when is_map(metadata) do
    with {:ok, artifacts} <- dependency_artifacts(),
         :ok <- unique_dependency_ids(artifacts) do
      required_dependency_map(Map.get(metadata, :dependencies, []), artifacts)
    end
  end

  def inputs(metadata, dependencies) when is_map(dependencies) do
    required = Map.get(metadata, :dependencies, [])

    Enum.reduce_while(required, {:ok, %{}}, fn id, {:ok, acc} ->
      case dependency_input(dependencies, id) do
        {:ok, interface, expected_fingerprint} ->
          {:cont,
           {:ok,
            Map.put(acc, id, %{plugin: interface, interface_fingerprint: expected_fingerprint})}}

        {:error, diagnostic} ->
          {:halt, {:error, diagnostic}}
      end
    end)
  end

  def inputs(metadata, :discover), do: discover(metadata)

  def inputs(_metadata, _dependencies) do
    {:error,
     Diagnostic.new!(
       :invalid_dependency_interfaces,
       "dependencies must be supplied as a map",
       source(nil)
     )}
  end

  defp dependency_input(dependencies, id) do
    case Map.fetch(dependencies, id) do
      {:ok, %{interface: interface, interface_fingerprint: expected_fingerprint}} ->
        if Compiler.fingerprint(interface) == expected_fingerprint do
          {:ok, interface, expected_fingerprint}
        else
          {:error,
           Diagnostic.new!(
             :stale_dependency_interface,
             "dependency #{inspect(id)} interface fingerprint is invalid",
             source(nil)
           )}
        end

      :error ->
        {:error,
         Diagnostic.new!(
           :missing_dependency_interface,
           "required dependency #{inspect(id)} has no compiled interface",
           source(nil)
         )}
    end
  end

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
    case dependency_app(app) do
      {:ok, app_dir, app_modules} -> load_dependency_catalog(app, app_dir, app_modules)
      :none -> :none
      {:error, reason} -> dependency_load_failure(app, reason)
    end
  end

  defp dependency_app(app) do
    case :code.lib_dir(app) do
      app_dir when is_list(app_dir) ->
        with :ok <- ensure_application_loaded(app),
             app_modules <- Application.spec(app, :modules) || [] do
          Enum.each(app_modules, &Code.ensure_loaded/1)
          {:ok, app_dir, app_modules}
        end

      _ ->
        :none
    end
  catch
    {:dependency_load_error, reason} -> {:error, reason}
  end

  defp ensure_application_loaded(app) do
    case :application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> throw({:dependency_load_error, reason})
    end
  end

  defp dependency_load_failure(app, reason) do
    {:error,
     Diagnostic.new!(
       :dependency_load_failed,
       "cannot load dependency #{inspect(app)} metadata: #{inspect(reason)}",
       source(nil)
     )}
  end

  defp load_dependency_catalog(app, app_dir, app_modules) do
    catalog_path = Path.join([List.to_string(app_dir), "priv", "wyram", "catalog.term"])

    if File.exists?(catalog_path) do
      read_dependency_catalog(app, catalog_path, app_modules)
    else
      :none
    end
  end

  defp read_dependency_catalog(app, catalog_path, app_modules) do
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
  end

  defp decode_artifact(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    error -> {:error, error}
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

    with :ok <- validate_module_names(owned, modules),
         {:ok, actual_hashes} <- actual_module_hashes(owned, app_modules_by_name),
         :ok <- validate_module_hashes(actual_hashes, hashes) do
      validate_interface_fingerprint(interface, expected)
    end
  end

  defp validate_artifact(_, _app_modules) do
    {:error,
     Diagnostic.new!(
       :invalid_dependency_catalog,
       "dependency artifact has an invalid shape",
       source(nil)
     )}
  end

  defp validate_module_names(owned, modules) do
    if owned == modules and Enum.sort(owned) == owned do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :invalid_dependency_modules,
         "dependency module ownership list is inconsistent",
         source(nil)
       )}
    end
  end

  defp actual_module_hashes(owned, modules_by_name) do
    Enum.reduce_while(owned, {:ok, %{}}, fn name, {:ok, hashes} ->
      case installed_module_hash(name, modules_by_name) do
        {:ok, hash} -> {:cont, {:ok, Map.put(hashes, name, hash)}}
        :error -> {:halt, {:error, missing_dependency_module()}}
      end
    end)
  end

  defp installed_module_hash(name, modules_by_name) do
    with module when is_atom(module) <- Map.get(modules_by_name, name),
         beam when is_list(beam) <- :code.which(module),
         {:ok, bytes} <- File.read(List.to_string(beam)) do
      {:ok, sha256(bytes)}
    else
      _ -> :error
    end
  end

  defp missing_dependency_module do
    Diagnostic.new!(
      :dependency_module_missing,
      "dependency package is missing a manifest-listed BEAM module",
      source(nil)
    )
  end

  defp validate_module_hashes(actual_hashes, expected_hashes) do
    if actual_hashes == expected_hashes do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :dependency_module_hash_mismatch,
         "dependency BEAM hashes do not match its compiled interface",
         source(nil)
       )}
    end
  end

  defp validate_interface_fingerprint(interface, expected) do
    if Compiler.fingerprint(interface) == expected do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :stale_dependency_interface,
         "dependency interface fingerprint does not match its catalog",
         source(nil)
       )}
    end
  end

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

  defp required_dependency_map(_required, _artifacts) do
    {:error,
     Diagnostic.new!(
       :invalid_dependency_list,
       "plugin dependencies must be a list",
       source(nil)
     )}
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source(_), do: %SourceLocation{file: "mix.exs", line: 1}
end
