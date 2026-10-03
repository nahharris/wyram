defmodule Wyram.Engine.PluginCatalog do
  @moduledoc "Validates installed compiled catalogs and builds immutable engine lookup tables."

  alias Wyram.Block.Ref
  alias Wyram.Engine.BlockRegistry
  alias Wyram.Game.Config
  alias Wyram.Plugin.{Content, Declaration, Descriptor, ModuleName, SourceLocation}

  @id_pattern ~r/^[a-z][a-z0-9_-]*$/
  @sha256_pattern ~r/^[0-9a-f]{64}$/
  @max_block_id 65_535
  @max_compile_data_bytes 16 * 1024 * 1024

  @spec build([map()], keyword()) :: {:ok, map()} | {:error, atom()}
  def build(packages, options \\ [])

  def build(packages, options) when is_list(packages) and is_list(options) do
    with :ok <- validate_packages(packages),
         {:ok, graph} <- validate_graph(packages),
         :ok <- validate_dependency_interfaces(packages, graph.by_id),
         {:ok, blocks} <- collect_blocks(packages),
         {:ok, content} <- collect_content(packages, blocks),
         :ok <- validate_all_game_refs(packages, blocks),
         {:ok, game_id, game} <- select_game(packages, Keyword.get(options, :game)),
         states <- BlockRegistry.expand(blocks),
         {:ok, block_ids} <- assign_block_ids(states, Keyword.get(options, :saved_block_ids, %{})) do
      {:ok,
       Map.merge(BlockRegistry.tables(states, block_ids), %{
         blocks: block_ids,
         content: Map.new(content, &{{&1.kind, &1.id}, &1.data}),
         placeable: Map.new(blocks, &{&1.id, block_ids[&1.id]}),
         colors:
           Map.new(states, fn block ->
             {Map.fetch!(block_ids, block.id), Tuple.to_list(block.descriptor.material.color)}
           end),
         palette: generation_palette(game.palette, block_ids),
         worldgen: game.worldgen,
         spawn_policy: game.spawn,
         player_profile: game.profile,
         character_definitions: game.characters,
         character_models: game.models,
         package_order: graph.order,
         versions:
           Map.new(packages, fn package ->
             {package.manifest["id"], package.manifest["version"]}
           end),
         game_id: game_id
       })}
    end
  rescue
    _ -> {:error, :invalid_plugin_catalog}
  end

  def build(_packages, _options), do: {:error, :invalid_plugin_catalog}

  defp generation_palette(nil, _block_ids), do: nil

  defp generation_palette(palette, block_ids) do
    Enum.map([:surface, :soil, :rock], fn role ->
      Map.fetch!(block_ids, Ref.canonical_id(Map.fetch!(palette, role)))
    end)
  end

  @spec interface_fingerprint(map()) :: String.t()
  def interface_fingerprint(interface) do
    interface
    |> then(&:erlang.term_to_binary(&1, [:deterministic]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_packages(packages) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      case validate_package(package) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_package(%{manifest: manifest, catalog: artifact})
       when is_map(manifest) and is_map(artifact) do
    if valid_manifest?(manifest) do
      validate_artifact(manifest, artifact)
    else
      {:error, :invalid_plugin_manifest}
    end
  end

  defp validate_package(_), do: {:error, :invalid_plugin_package}

  defp valid_manifest?(manifest) do
    with id when is_binary(id) <- manifest["id"],
         true <- valid_id?(id),
         version when is_binary(version) <- manifest["version"],
         otp when is_binary(otp) <- manifest["otp"],
         elixir when is_binary(elixir) <- manifest["elixir"],
         entry when is_binary(entry) <- manifest["entry"],
         modules when is_list(modules) and modules != [] <- manifest["modules"],
         dependencies when is_list(dependencies) <- manifest["dependencies"],
         "catalog.term" <- manifest["catalog"],
         hash when is_binary(hash) <- manifest["catalog_sha256"] do
      valid_module_list?(modules) and valid_module?(entry) and entry in modules and
        Enum.all?(dependencies, &valid_id?/1) and valid_hash?(hash) and version != "" and
        otp != "" and
        elixir != ""
    else
      _ -> false
    end
  end

  defp validate_artifact(manifest, artifact) do
    with :ok <- valid_catalog_magic(artifact),
         {:ok, plugin, catalog, interface, dependency_interfaces} <-
           artifact_components(artifact),
         :ok <- valid_interface_payload(interface, Map.get(artifact, :interface_fingerprint)) do
      validate_artifact_maps(manifest, plugin, catalog, interface, dependency_interfaces)
    end
  end

  defp valid_catalog_magic(artifact) do
    if Map.get(artifact, :magic) == :wyram_plugin_catalog,
      do: :ok,
      else: {:error, :invalid_plugin_catalog}
  end

  defp artifact_components(artifact) do
    plugin = Map.get(artifact, :plugin)
    catalog = Map.get(artifact, :catalog)
    interface = Map.get(artifact, :interface)
    dependency_interfaces = Map.get(artifact, :dependency_interfaces)

    if is_map(plugin) and is_map(catalog) and is_map(interface) and
         is_map(dependency_interfaces) do
      {:ok, plugin, catalog, interface, dependency_interfaces}
    else
      {:error, :invalid_plugin_catalog}
    end
  end

  defp valid_interface_payload(interface, stored_fingerprint) do
    cond do
      not valid_compile_data?(Map.get(interface, :compile_data)) ->
        {:error, :invalid_catalog_interface}

      not valid_hash?(stored_fingerprint) or
          stored_fingerprint != interface_fingerprint(interface) ->
        {:error, :stale_plugin_interface}

      true ->
        :ok
    end
  end

  defp validate_artifact_maps(manifest, plugin, catalog, interface, _dependency_interfaces) do
    cond do
      not matching_identity?(manifest, plugin, catalog, interface) ->
        {:error, :catalog_identity_mismatch}

      not matching_dependencies?(manifest, plugin, catalog, interface) ->
        {:error, :catalog_dependency_mismatch}

      plugin[:owned_modules] != manifest["modules"] or interface[:modules] != manifest["modules"] ->
        {:error, :catalog_module_mismatch}

      not valid_interface?(manifest, plugin, catalog, interface) ->
        {:error, :invalid_catalog_interface}

      not valid_game_data?(catalog[:game], plugin[:game]) ->
        {:error, :invalid_game_configuration}

      true ->
        validate_blocks(catalog[:blocks], manifest["id"], manifest["modules"], interface)
    end
  end

  defp matching_identity?(manifest, plugin, catalog, interface) do
    id = manifest["id"]

    plugin[:id] == id and plugin[:entry] == manifest["entry"] and catalog[:id] == id and
      interface[:id] == id and interface[:entry] == manifest["entry"]
  end

  defp matching_dependencies?(manifest, plugin, catalog, interface) do
    dependencies = manifest["dependencies"]

    plugin[:dependencies] == dependencies and catalog[:dependencies] == dependencies and
      interface[:dependencies] == dependencies
  end

  defp valid_interface?(manifest, plugin, catalog, interface) do
    providers = plugin[:provider_modules]
    modules = manifest["modules"]

    interface[:providers] == providers and interface[:game] == plugin[:game] and
      interface[:compiled_blocks] == catalog[:blocks] and valid_module_list?(providers) and
      matching_compiled_content?(interface, catalog) and
      Enum.all?(providers, &(&1 in modules)) and
      valid_interface_declarations?(interface[:declarations], manifest["id"], modules) and
      valid_module_hashes?(interface[:module_hashes], modules) and
      valid_game_module?(plugin[:game], modules)
  end

  defp matching_compiled_content?(interface, catalog),
    do:
      interface[:compiled_game] == catalog[:game] and
        interface[:compiled_content] == catalog[:content]

  defp valid_compile_data?(<<131, tag, _rest::binary>> = bytes)
       when byte_size(bytes) <= @max_compile_data_bytes and tag != 80,
       do: true

  defp valid_compile_data?(_), do: false

  defp collect_content(packages, blocks) do
    valid =
      Enum.all?(packages, fn package ->
        Content.valid_records?(
          package.catalog.catalog[:content],
          package.manifest["id"],
          package.manifest["modules"]
        )
      end)

    if valid do
      records = Enum.flat_map(packages, & &1.catalog.catalog.content)
      index = Map.new(records ++ blocks, &{{&1.kind, &1.id}, &1})

      linked =
        Enum.all?(packages, fn package ->
          allowed = [package.manifest["id"] | package.manifest["dependencies"]]
          Enum.all?(package.catalog.catalog.content, &Content.links_valid?(&1, index, allowed))
        end)

      if linked, do: {:ok, records}, else: {:error, :invalid_content_catalog}
    else
      {:error, :invalid_content_catalog}
    end
  end

  defp valid_module_hashes?(hashes, modules) when is_map(hashes) do
    Map.keys(hashes) |> Enum.sort() == modules and Enum.all?(Map.values(hashes), &valid_hash?/1)
  end

  defp valid_module_hashes?(_, _), do: false

  defp valid_game_module?(nil, _modules), do: true
  defp valid_game_module?(module, modules), do: valid_module?(module) and module in modules

  defp valid_interface_declarations?(declarations, plugin_id, modules)
       when is_list(declarations) do
    Enum.all?(
      declarations,
      &valid_interface_declaration?(&1, plugin_id, modules)
    ) and
      length(Enum.uniq_by(declarations, & &1.module)) == length(declarations)
  rescue
    _ -> false
  end

  defp valid_interface_declarations?(_, _, _), do: false

  defp valid_interface_declaration?(%Declaration{entries: []} = declaration, plugin_id, modules) do
    valid_declaration_shape?(declaration) and ModuleName.valid?(declaration.module) and
      declaration.plugin_id == plugin_id and
      Atom.to_string(declaration.module) in modules and
      declaration.kind == :block and valid_declaration_role?(declaration) and
      SourceLocation.valid?(declaration.source)
  end

  defp valid_interface_declaration?(_, _, _), do: false

  defp valid_declaration_shape?(declaration) do
    Map.keys(declaration) |> Enum.sort() ==
      [:__struct__, :entries, :kind, :local_id, :module, :plugin_id, :role, :source]
  end

  defp valid_declaration_role?(%Declaration{role: :registered, local_id: id}), do: valid_id?(id)
  defp valid_declaration_role?(%Declaration{role: :template, local_id: nil}), do: true
  defp valid_declaration_role?(_), do: false

  defp valid_game_data?(nil, nil), do: true

  defp valid_game_data?(%Config{} = config, module) when is_binary(module),
    do: Config.validate(config) == :ok

  defp valid_game_data?(_, _), do: false

  defp validate_blocks(blocks, plugin_id, modules, interface) when is_list(blocks) do
    declarations = Map.get(interface, :declarations, [])

    cond do
      not Enum.all?(blocks, &valid_block_shape?/1) ->
        {:error, :invalid_catalog_block}

      not registered_declarations_match_blocks?(declarations, blocks) ->
        {:error, :invalid_catalog_ownership}

      Enum.any?(blocks, &(not valid_block_owner?(&1, plugin_id, modules, declarations))) ->
        {:error, :invalid_catalog_ownership}

      Enum.any?(blocks, &(not valid_descriptor?(&1.descriptor))) ->
        {:error, :unsupported_block_descriptor}

      Enum.any?(blocks, &(not valid_source?(&1.source))) ->
        {:error, :invalid_catalog_source}

      length(Enum.uniq_by(blocks, & &1.id)) != length(blocks) ->
        {:error, :duplicate_block_id}

      true ->
        :ok
    end
  end

  defp validate_blocks(_, _, _, _), do: {:error, :invalid_catalog_blocks}

  defp valid_block_shape?(block) when is_map(block) do
    expected_keys = [:id, :plugin_id, :local_id, :module, :kind, :descriptor, :source]
    Map.keys(block) |> Enum.sort() == Enum.sort(expected_keys)
  end

  defp valid_block_shape?(_), do: false

  defp registered_declarations_match_blocks?(declarations, blocks) do
    registered =
      Enum.flat_map(declarations, fn
        %Declaration{
          plugin_id: plugin_id,
          local_id: local_id,
          module: module,
          role: :registered
        } ->
          [{plugin_id, local_id, Atom.to_string(module)}]

        _ ->
          []
      end)

    registered_ids =
      Enum.map(registered, fn {plugin_id, local_id, _module} -> {plugin_id, local_id} end)

    block_ids = Enum.map(blocks, &{&1.plugin_id, &1.local_id, &1.module})

    length(registered) == length(blocks) and
      length(Enum.uniq(registered_ids)) == length(registered) and
      Enum.sort(registered) == Enum.sort(block_ids)
  end

  defp valid_block_owner?(block, plugin_id, modules, declarations) do
    block_id = Map.get(block, :id)
    local_id = Map.get(block, :local_id)
    module = Map.get(block, :module)

    Map.get(block, :plugin_id) == plugin_id and valid_id?(local_id) and
      block_id == plugin_id <> ":" <> local_id and valid_module?(module) and module in modules and
      Enum.any?(declarations, fn
        %Declaration{
          plugin_id: owner,
          local_id: declaration_id,
          module: declaration_module,
          kind: :block,
          role: :registered,
          entries: []
        } ->
          owner == plugin_id and declaration_id == local_id and
            Atom.to_string(declaration_module) == module

        _ ->
          false
      end) and Map.get(block, :kind) == :block
  end

  defp valid_descriptor?(descriptor), do: Descriptor.valid?(descriptor)

  defp valid_source?(%{file: file, line: line} = source) do
    Map.keys(source) -- [:file, :line, :column, :module] == [] and is_binary(file) and file != "" and
      is_integer(line) and line > 0 and
      valid_source_column?(Map.get(source, :column)) and
      valid_source_module?(Map.get(source, :module))
  end

  defp valid_source?(_), do: false
  defp valid_source_column?(nil), do: true
  defp valid_source_column?(column), do: is_integer(column) and column > 0
  defp valid_source_module?(nil), do: true
  defp valid_source_module?(module), do: valid_module?(module)

  defp validate_graph(packages) do
    manifests = Enum.map(packages, & &1.manifest)
    ids = Enum.map(manifests, & &1["id"])
    modules = Enum.flat_map(manifests, & &1["modules"])
    by_id = Map.new(packages, &{&1.manifest["id"], &1})

    cond do
      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :duplicate_plugin_id}

      length(Enum.uniq(modules)) != length(modules) ->
        {:error, :module_ownership_collision}

      Enum.any?(manifests, fn manifest -> manifest["id"] in manifest["dependencies"] end) ->
        {:error, :self_dependency}

      Enum.any?(manifests, fn manifest -> not unique_ids?(manifest["dependencies"]) end) ->
        {:error, :duplicate_dependency}

      Enum.any?(manifests, fn manifest ->
        Enum.any?(manifest["dependencies"], &(not Map.has_key?(by_id, &1)))
      end) ->
        {:error, :missing_dependency}

      true ->
        case dependency_order(by_id, Enum.sort(ids)) do
          {:ok, order} -> {:ok, %{by_id: by_id, order: order}}
          error -> error
        end
    end
  end

  defp dependency_order(by_id, ids) do
    Enum.reduce_while(ids, {:ok, %{done: MapSet.new(), visiting: MapSet.new(), order: []}}, fn id,
                                                                                               {:ok,
                                                                                                state} ->
      case visit(id, by_id, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, Enum.reverse(state.order)}
      error -> error
    end
  end

  defp visit(id, by_id, state) do
    cond do
      MapSet.member?(state.done, id) ->
        {:ok, state}

      MapSet.member?(state.visiting, id) ->
        {:error, :cyclic_plugin_dependencies}

      true ->
        package = Map.fetch!(by_id, id)
        visiting = MapSet.put(state.visiting, id)

        with {:ok, after_dependencies} <-
               visit_dependencies(package.manifest["dependencies"], by_id, %{
                 state
                 | visiting: visiting
               }) do
          {:ok,
           %{
             after_dependencies
             | visiting: MapSet.delete(after_dependencies.visiting, id),
               done: MapSet.put(after_dependencies.done, id),
               order: [id | after_dependencies.order]
           }}
        end
    end
  end

  defp visit_dependencies(dependencies, by_id, state) do
    dependencies
    |> Enum.sort()
    |> Enum.reduce_while({:ok, state}, fn id, {:ok, acc} ->
      case visit(id, by_id, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_dependency_interfaces(packages, by_id) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      if matching_dependency_interfaces?(package, by_id),
        do: {:cont, :ok},
        else: {:halt, {:error, :stale_dependency_interface}}
    end)
  end

  defp matching_dependency_interfaces?(package, by_id) do
    hashes = package.catalog.dependency_interfaces
    dependencies = package.manifest["dependencies"]

    is_map(hashes) and Enum.sort(Map.keys(hashes)) == Enum.sort(dependencies) and
      Enum.all?(dependencies, fn id ->
        valid_hash?(Map.get(hashes, id)) and
          hashes[id] == interface_fingerprint(by_id[id].catalog.interface)
      end)
  end

  defp collect_blocks(packages) do
    blocks = Enum.flat_map(packages, & &1.catalog.catalog.blocks)
    ids = Enum.map(blocks, & &1.id)

    if length(ids) == length(Enum.uniq(ids)),
      do: {:ok, Enum.sort_by(blocks, & &1.id)},
      else: {:error, :duplicate_block_id}
  end

  defp select_game(packages, nil) do
    case Enum.filter(packages, &(not is_nil(&1.catalog.catalog.game))) do
      [%{manifest: manifest, catalog: artifact}] -> {:ok, manifest["id"], artifact.catalog.game}
      [] -> {:error, :missing_game_configuration}
      _ -> {:error, :ambiguous_game_configuration}
    end
  end

  defp select_game(packages, id) when is_binary(id) do
    case Enum.find(packages, &(&1.manifest["id"] == id and not is_nil(&1.catalog.catalog.game))) do
      %{catalog: artifact} -> {:ok, id, artifact.catalog.game}
      nil -> {:error, :unknown_game_configuration}
    end
  end

  defp select_game(_packages, _id), do: {:error, :invalid_game_selection}

  defp validate_all_game_refs(packages, blocks) do
    Enum.reduce_while(packages, :ok, fn
      %{manifest: manifest, catalog: %{catalog: %{game: %Config{} = game}}}, :ok ->
        allowed_plugins = [manifest["id"] | manifest["dependencies"]]

        if valid_game_refs?(game, allowed_plugins, blocks) do
          {:cont, :ok}
        else
          {:halt, {:error, :invalid_game_configuration}}
        end

      %{catalog: %{catalog: %{game: nil}}}, :ok ->
        {:cont, :ok}

      _package, :ok ->
        {:halt, {:error, :invalid_game_configuration}}
    end)
  end

  defp valid_game_refs?(game, allowed_plugins, blocks) do
    Config.validate(game) == :ok and
      Enum.all?(
        Config.references(game),
        &valid_game_ref?(&1, allowed_plugins, blocks)
      )
  end

  defp valid_game_ref?(%Ref{plugin_id: plugin_id} = ref, allowed_plugins, blocks),
    do: plugin_id in allowed_plugins and Enum.any?(blocks, &(&1.id == Ref.canonical_id(ref)))

  defp valid_game_ref?(_, _, _), do: false

  defp assign_block_ids(blocks, saved_ids) do
    with :ok <- validate_saved_ids(saved_ids),
         :ok <- validate_saved_names(saved_ids, blocks) do
      names = Enum.map(blocks, & &1.id)
      assigned = Map.take(saved_ids, names)
      max_id = saved_ids |> Map.values() |> Enum.max(fn -> 0 end)

      Enum.reduce_while(names, {:ok, {assigned, max_id}}, fn name, {:ok, {ids, current}} ->
        assign_block_id(name, ids, current)
      end)
      |> case do
        {:ok, {ids, _next}} -> {:ok, ids}
        error -> error
      end
    end
  end

  defp assign_block_id(name, ids, current) do
    if Map.has_key?(ids, name) do
      {:cont, {:ok, {ids, current}}}
    else
      next = current + 1

      if next <= @max_block_id,
        do: {:cont, {:ok, {Map.put(ids, name, next), next}}},
        else: {:halt, {:error, :block_id_capacity_exceeded}}
    end
  end

  defp validate_saved_ids(ids) when is_map(ids) do
    values = Map.values(ids)

    if Enum.all?(ids, fn {name, id} ->
         valid_canonical_id?(name) and is_integer(id) and id in 1..@max_block_id
       end) and
         length(values) == length(Enum.uniq(values)),
       do: :ok,
       else: {:error, :invalid_saved_block_ids}
  end

  defp validate_saved_ids(_), do: {:error, :invalid_saved_block_ids}

  defp validate_saved_names(saved_ids, blocks) do
    active = MapSet.new(blocks, & &1.id)

    if Enum.all?(Map.keys(saved_ids), &MapSet.member?(active, &1)),
      do: :ok,
      else: {:error, :invalid_saved_block_ids}
  end

  defp valid_canonical_id?(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [plugin_id, local_state] -> valid_id?(plugin_id) and valid_local_state?(local_state)
      _ -> false
    end
  end

  defp valid_canonical_id?(_), do: false

  defp valid_local_state?(value) do
    case String.split(value, "#") do
      [id] -> valid_id?(id)
      [id, "falling"] -> valid_id?(id)
      [id, "flow_" <> level] -> valid_id?(id) and level in ~w(1 2 3 4 5 6 7)
      _ -> false
    end
  end

  defp valid_module_list?(modules) when is_list(modules),
    do: modules == Enum.sort(Enum.uniq(modules)) and Enum.all?(modules, &valid_module?/1)

  defp valid_module_list?(_), do: false

  defp valid_module?(name), do: ModuleName.valid_string?(name)

  defp valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  defp valid_id?(_), do: false

  defp valid_hash?(hash) when is_binary(hash), do: Regex.match?(@sha256_pattern, hash)
  defp valid_hash?(_), do: false

  defp unique_ids?(values), do: length(values) == length(Enum.uniq(values))
end
