defmodule Wyram.Plugin.Compiler.DependencyArtifacts do
  @moduledoc false

  alias Wyram.Plugin.{Compiler, Declaration, Diagnostic, SourceLocation}

  @magic :wyram_plugin_catalog
  @max_compile_data_bytes 16 * 1024 * 1024
  @max_catalog_bytes 16 * 1024 * 1024

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

  def inputs(metadata, :discover) do
    with {:ok, dependencies} <- discover(metadata) do
      inputs(metadata, dependencies)
    end
  end

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
        validate_dependency_input(interface, expected_fingerprint, id)

      :error ->
        {:error,
         Diagnostic.new!(
           :missing_dependency_interface,
           "required dependency #{inspect(id)} has no compiled interface",
           source(nil)
         )}
    end
  end

  defp validate_dependency_input(interface, expected_fingerprint, id) do
    with :ok <- validate_interface_compile_data_size(interface),
         :ok <- validate_dependency_fingerprint(interface, expected_fingerprint, id),
         {:ok, restored} <- restore_compile_data(interface) do
      {:ok, restored, expected_fingerprint}
    end
  end

  defp validate_dependency_fingerprint(interface, expected_fingerprint, id) do
    if Compiler.fingerprint(interface) == expected_fingerprint,
      do: :ok,
      else:
        {:error,
         Diagnostic.new!(
           :stale_dependency_interface,
           "dependency #{inspect(id)} interface fingerprint is invalid",
           source(nil)
         )}
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
    with {:ok, bytes} <- read_catalog_bytes(catalog_path),
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

  defp read_catalog_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_catalog_bytes -> File.read(path)
      {:ok, _stat} -> {:error, :dependency_catalog_too_large}
      error -> error
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

    with :ok <- validate_interface_compile_data_size(interface),
         :ok <- validate_module_names(owned, modules),
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

  defp restore_compile_data(%{compile_data: bytes, declarations: summaries} = interface)
       when is_binary(bytes) and is_list(summaries) do
    with :ok <- validate_compile_data_size(bytes),
         :ok <- reject_compressed_compile_data(bytes),
         {:ok, %{declarations: declarations, plugins: plugins}} <- decode_compile_data(bytes),
         :ok <- validate_compile_data_lists(declarations, plugins),
         :ok <- validate_declaration_summaries(declarations, summaries),
         :ok <- validate_compile_data_owner(declarations, plugins, interface) do
      {:ok, Map.merge(interface, %{declarations: declarations, plugins: plugins})}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, diagnostic}
      _ -> {:error, invalid_compile_data()}
    end
  end

  defp restore_compile_data(_interface), do: {:error, invalid_compile_data()}

  defp validate_compile_data_size(bytes) do
    if byte_size(bytes) <= @max_compile_data_bytes,
      do: :ok,
      else: {:error, invalid_compile_data()}
  end

  defp validate_interface_compile_data_size(%{compile_data: bytes}) when is_binary(bytes),
    do: validate_compile_data_size(bytes)

  defp validate_interface_compile_data_size(_interface), do: {:error, invalid_compile_data()}

  defp reject_compressed_compile_data(<<131, 80, _rest::binary>>),
    do: {:error, invalid_compile_data()}

  defp reject_compressed_compile_data(<<131, _tag, _rest::binary>>), do: :ok
  defp reject_compressed_compile_data(_bytes), do: {:error, invalid_compile_data()}

  defp decode_compile_data(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      %{declarations: declarations, plugins: plugins} = data
      when map_size(data) == 2 ->
        {:ok, %{declarations: declarations, plugins: plugins}}

      _ ->
        {:error, invalid_compile_data()}
    end
  rescue
    ArgumentError -> {:error, invalid_compile_data()}
  end

  defp validate_compile_data_lists(declarations, plugins) do
    valid_declarations =
      is_list(declarations) and Enum.all?(declarations, &match?(%Declaration{}, &1))

    valid_plugins = is_list(plugins) and Enum.all?(plugins, &is_map/1)

    if valid_declarations and valid_plugins,
      do: :ok,
      else: {:error, invalid_compile_data()}
  end

  defp validate_declaration_summaries(declarations, summaries) do
    expected_summaries = Enum.map(declarations, &%{&1 | entries: []})

    if summaries == expected_summaries,
      do: :ok,
      else: {:error, invalid_compile_data()}
  end

  defp validate_compile_data_owner(declarations, [owner | _], interface) when is_map(owner) do
    valid_owner =
      owner_matches_interface?(owner, interface) and Map.get(owner, :declarations) == declarations

    if valid_owner, do: :ok, else: {:error, invalid_compile_data()}
  end

  defp validate_compile_data_owner(_declarations, _plugins, _interface),
    do: {:error, invalid_compile_data()}

  defp owner_matches_interface?(owner, interface) do
    owner_identity_matches?(owner, interface) and owner_dependencies_match?(owner, interface) and
      owner_modules_match?(owner, interface) and
      Map.get(owner, :module_hashes) == interface.module_hashes
  end

  defp owner_identity_matches?(owner, interface) do
    Map.get(owner, :id) == interface.id and
      module_name(Map.get(owner, :entry)) == interface.entry and
      module_name(Map.get(owner, :game)) == interface.game
  end

  defp owner_dependencies_match?(owner, interface) do
    dependencies = Map.get(owner, :dependencies)
    is_list(dependencies) and Enum.sort(dependencies) == interface.dependencies
  end

  defp owner_modules_match?(owner, interface) do
    module_names(Map.get(owner, :modules)) == interface.modules and
      module_names(Map.get(owner, :providers)) == interface.providers
  end

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(_module), do: nil

  defp module_names(modules) when is_list(modules), do: Enum.map(modules, &module_name/1)
  defp module_names(_modules), do: nil

  defp invalid_compile_data do
    Diagnostic.new!(
      :invalid_dependency_compile_data,
      "dependency interface has invalid declaration compile data",
      source(nil)
    )
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
