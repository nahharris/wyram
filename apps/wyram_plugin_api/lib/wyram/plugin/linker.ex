defmodule Wyram.Plugin.Linker do
  @moduledoc "Links collected plugin declarations into deterministic logical catalogs."

  alias Wyram.Block.Ref

  alias Wyram.Plugin.{
    BlockDefaults,
    CapabilityContribution,
    Declaration,
    Diagnostic,
    ModuleName,
    Provider,
    SourceLocation
  }

  alias Wyram.Plugin.Declaration.Template
  alias Wyram.Plugin.DSL.{Capability, StructLiteral}

  @default_expansion_budget 1_024
  @generated_marker :__wyram_generated_declaration__

  @type plugin_input :: %{
          required(:id) => String.t(),
          required(:entry) => module(),
          required(:dependencies) => [String.t()],
          required(:declarations) => [Declaration.t()],
          optional(:providers) => [module()],
          optional(:modules) => [module()],
          optional(:game) => module() | nil
        }

  @doc "Links an installed set of plugin metadata and collected declarations."
  @spec link_set([plugin_input()], keyword()) :: {:ok, map()} | {:error, [Diagnostic.t()]}
  def link_set(plugins, options \\ [])

  def link_set(plugins, options) when is_list(plugins) and is_list(options) do
    budget = Keyword.get(options, :max_template_expansions, @default_expansion_budget)

    with :ok <- validate_options(options, budget),
         {:ok, normalized} <- normalize_plugins(plugins),
         :ok <- unique_plugin_ids(normalized),
         :ok <- unique_owned_modules(normalized),
         :ok <- validate_dependencies(normalized),
         {:ok, order} <- dependency_order(normalized),
         :ok <- unique_declarations(normalized),
         :ok <- validate_generated_modules(normalized),
         :ok <- validate_templates(normalized),
         {:ok, candidates} <- provider_candidates(normalized),
         {:ok, expanded} <- expand_declarations(normalized, candidates, budget) do
      {:ok, build_result(normalized, order, expanded)}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, [diagnostic]}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError] ->
      source = source_for(hd_or_nil(plugins))

      {:error,
       [
         Diagnostic.new!(
           :invalid_link_input,
           "invalid plugin linker input: #{Exception.message(error)}",
           source
         )
       ]}
  end

  def link_set(_plugins, _options) do
    {:error,
     [Diagnostic.new!(:invalid_link_input, "plugin inputs must be a list", source_for(nil))]}
  end

  @doc "Links one plugin against already compiled dependency interfaces."
  @spec link_plugin(map(), [Declaration.t()], map(), keyword()) ::
          {:ok, map()} | {:error, [Diagnostic.t()]}
  def link_plugin(metadata, declarations, dependency_interfaces, options)

  def link_plugin(metadata, declarations, dependency_interfaces, options)
      when is_map(metadata) and is_list(declarations) and is_map(dependency_interfaces) do
    required = Map.get(metadata, :dependencies, [])

    with :ok <- validate_required_interfaces(required, dependency_interfaces, metadata),
         {:ok, dependency_plugins} <- dependency_plugins(required, dependency_interfaces),
         {:ok, dependencies} <- deduplicate_dependency_plugins(dependency_plugins, metadata) do
      current = Map.merge(metadata, %{declarations: declarations})
      link_plugin_set(dependencies, current, options)
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
    end
  rescue
    error in [KeyError, ArgumentError] ->
      {:error,
       [
         Diagnostic.new!(
           :invalid_dependency_interface,
           "invalid compiled dependency interface: #{Exception.message(error)}",
           source_for(metadata)
         )
       ]}
  end

  def link_plugin(_metadata, _declarations, _dependency_interfaces, _options) do
    {:error,
     [
       Diagnostic.new!(
         :invalid_link_input,
         "invalid plugin or dependency interface",
         source_for(nil)
       )
     ]}
  end

  defp validate_required_interfaces(required, interfaces, metadata) do
    missing = Enum.reject(required, &Map.has_key?(interfaces, &1))

    if missing == [] do
      :ok
    else
      {:error,
       Enum.map(missing, fn dependency ->
         Diagnostic.new!(
           :missing_dependency,
           "required plugin dependency #{inspect(dependency)} has no compiled interface",
           source_for(metadata)
         )
       end)}
    end
  end

  defp dependency_plugins(required, interfaces) do
    plugins =
      Enum.flat_map(required, fn dependency ->
        interfaces
        |> Map.fetch!(dependency)
        |> dependency_interface_plugins()
      end)

    {:ok, plugins}
  end

  defp dependency_interface_plugins(interface) do
    interface = Map.get(interface, :interface, Map.get(interface, :plugin, interface))

    case Map.fetch(interface, :plugins) do
      {:ok, plugins} when is_list(plugins) -> plugins
      _ -> [Map.fetch!(interface, :plugin)]
    end
  end

  defp link_plugin_set(dependencies, current, options) do
    with {:ok, linked} <- link_set(dependencies ++ [current], options) do
      id = Map.fetch!(current, :id)

      {:ok,
       %{
         catalog: Map.fetch!(linked.catalogs, id),
         interface: Map.fetch!(linked.interfaces, id)
       }}
    end
  end

  defp deduplicate_dependency_plugins(plugins, metadata) do
    conflicts =
      plugins
      |> Enum.group_by(&Map.get(&1, :id))
      |> Enum.filter(fn {_id, definitions} -> length(Enum.uniq(definitions)) > 1 end)

    if conflicts == [] do
      {:ok, Enum.uniq_by(plugins, & &1.id)}
    else
      {:error,
       Enum.map(conflicts, fn {id, _definitions} ->
         Diagnostic.new!(
           :conflicting_dependency_interface,
           "multiple required dependency interfaces provide conflicting metadata for plugin #{inspect(id)}",
           source_for(metadata)
         )
       end)}
    end
  end

  defp validate_options(options, budget) do
    if Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Keyword.keys(options) -- [:max_template_expansions] == [] and is_integer(budget) and
         budget > 0 do
      :ok
    else
      {:error,
       Diagnostic.new!(
         :invalid_link_options,
         "linker options must contain only unique supported keys and a positive expansion budget",
         source_for(nil)
       )}
    end
  end

  defp normalize_plugins(plugins) do
    if Enum.all?(plugins, &valid_plugin_input?/1) do
      {:ok, plugins |> Enum.map(&normalize_plugin/1) |> Enum.sort_by(& &1.id)}
    else
      {:error,
       Diagnostic.new!(
         :invalid_link_input,
         "each plugin needs an ID, entry module, dependency list, and declaration list",
         source_for(hd_or_nil(plugins))
       )}
    end
  end

  defp normalize_plugin(plugin) do
    plugin = Map.merge(%{providers: [], modules: [], game: nil}, plugin)

    Map.update!(plugin, :declarations, fn declarations ->
      Enum.map(declarations, &normalize_collected_declaration(&1, plugin))
    end)
  end

  defp valid_plugin_input?(plugin) when is_map(plugin) do
    valid_plugin_identity?(plugin) and valid_plugin_collections?(plugin) and
      valid_plugin_members?(plugin)
  end

  defp valid_plugin_input?(_), do: false

  defp valid_plugin_identity?(plugin) do
    Ref.valid_plugin_id?(Map.get(plugin, :id)) and ModuleName.valid?(Map.get(plugin, :entry)) and
      (is_nil(Map.get(plugin, :game)) or ModuleName.valid?(Map.get(plugin, :game)))
  end

  defp valid_plugin_collections?(plugin) do
    Enum.all?([:dependencies, :declarations], &is_list(Map.get(plugin, &1))) and
      Enum.all?([:providers, :modules], &is_list(Map.get(plugin, &1, [])))
  end

  defp valid_plugin_members?(plugin) do
    Enum.all?(Map.get(plugin, :dependencies), &Ref.valid_plugin_id?/1) and
      Enum.all?(Map.get(plugin, :providers, []), &ModuleName.valid?/1) and
      Enum.all?(Map.get(plugin, :modules, []), &ModuleName.valid?/1)
  end

  defp provider_candidates(plugins) do
    by_id = Map.new(plugins, &{&1.id, &1})

    Enum.reduce_while(plugins, {:ok, %{}}, fn plugin, {:ok, acc} ->
      dependency_providers =
        plugin.dependencies
        |> Enum.flat_map(fn dependency -> Map.fetch!(by_id, dependency).providers end)

      candidates =
        Enum.uniq(Provider.builtins() ++ plugin.providers ++ dependency_providers)

      invalid = Enum.reject(candidates, &valid_provider_candidate?(&1, candidates))

      if invalid == [] do
        {:cont, {:ok, Map.put(acc, plugin.id, candidates)}}
      else
        {:halt,
         {:error,
          Enum.map(invalid, fn provider ->
            Diagnostic.new!(
              :invalid_provider,
              "provider #{inspect(provider)} does not satisfy the public provider contract or has ambiguous config ownership",
              source_for(plugin)
            )
          end)}}
      end
    end)
  end

  defp valid_provider_candidate?(provider, candidates) do
    ModuleName.valid?(provider) and Code.ensure_loaded?(provider) and
      function_exported?(provider, :config_module, 0) and
      match?({:ok, ^provider}, Provider.for_config(provider.config_module(), candidates))
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp unique_plugin_ids(plugins) do
    duplicates = duplicates_by(plugins, & &1.id)

    if duplicates == [] do
      :ok
    else
      {:error,
       Enum.map(duplicates, fn id ->
         Diagnostic.new!(
           :duplicate_plugin_id,
           "plugin ID #{inspect(id)} is installed more than once",
           source_for(find_plugin(plugins, id))
         )
       end)}
    end
  end

  defp unique_owned_modules(plugins) do
    modules = Enum.flat_map(plugins, & &1.modules)

    duplicates = duplicates(modules)

    if duplicates == [] do
      :ok
    else
      {:error,
       Enum.map(duplicates, fn module ->
         Diagnostic.new!(
           :duplicate_module,
           "module #{inspect(module)} is owned by more than one plugin or is listed more than once",
           source_for(find_module_declaration(plugins, module))
         )
       end)}
    end
  end

  defp validate_dependencies(plugins) do
    ids = MapSet.new(Enum.map(plugins, & &1.id))

    diagnostics =
      Enum.flat_map(plugins, fn plugin ->
        duplicates = duplicates(plugin.dependencies)

        duplicate_diagnostics =
          Enum.map(duplicates, fn dependency ->
            Diagnostic.new!(
              :duplicate_dependency,
              "plugin #{plugin.id} lists dependency #{inspect(dependency)} more than once",
              source_for(plugin)
            )
          end)

        missing_diagnostics =
          Enum.flat_map(plugin.dependencies, fn dependency ->
            cond do
              dependency == plugin.id ->
                [
                  Diagnostic.new!(
                    :dependency_cycle,
                    "plugin #{plugin.id} depends on itself",
                    source_for(plugin),
                    path: [plugin.id, plugin.id]
                  )
                ]

              not MapSet.member?(ids, dependency) ->
                [
                  Diagnostic.new!(
                    :missing_dependency,
                    "plugin #{plugin.id} requires missing plugin #{inspect(dependency)}",
                    source_for(plugin)
                  )
                ]

              true ->
                []
            end
          end)

        duplicate_diagnostics ++ missing_diagnostics
      end)

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp dependency_order(plugins) do
    by_id = Map.new(plugins, &{&1.id, &1})
    walk_dependencies(Enum.map(plugins, & &1.id), by_id, MapSet.new(), [], [])
  end

  defp walk_dependencies([], _by_id, _complete, _active, order),
    do: {:ok, Enum.reverse(order)}

  defp walk_dependencies([id | rest], by_id, complete, active, order) do
    case visit_plugin(id, by_id, complete, active, order) do
      {:ok, next_complete, next_order} ->
        walk_dependencies(rest, by_id, next_complete, [], next_order)

      error ->
        error
    end
  end

  defp visit_plugin(id, by_id, complete, active, order) do
    cond do
      MapSet.member?(complete, id) ->
        {:ok, complete, order}

      id in active ->
        cycle = Enum.drop_while(active, &(&1 != id)) ++ [id]
        plugin = Map.fetch!(by_id, id)

        {:error,
         Diagnostic.new!(
           :dependency_cycle,
           "plugin dependency cycle: #{Enum.join(cycle, " -> ")}",
           source_for(plugin),
           path: cycle
         )}

      true ->
        plugin = Map.fetch!(by_id, id)

        visit_dependencies(plugin, by_id, complete, active, order)
    end
  end

  defp visit_dependencies(plugin, by_id, complete, active, order) do
    result =
      Enum.reduce_while(Enum.sort(plugin.dependencies), {:ok, complete, order}, fn dependency,
                                                                                   {:ok, seen,
                                                                                    acc} ->
        case visit_plugin(dependency, by_id, seen, active ++ [plugin.id], acc) do
          {:ok, next_seen, next_acc} -> {:cont, {:ok, next_seen, next_acc}}
          error -> {:halt, error}
        end
      end)

    mark_plugin_visited(result, plugin.id)
  end

  defp mark_plugin_visited({:ok, seen, order}, id) do
    if MapSet.member?(seen, id),
      do: {:ok, seen, order},
      else: {:ok, MapSet.put(seen, id), [id | order]}
  end

  defp mark_plugin_visited(error, _id), do: error

  defp unique_declarations(plugins) do
    declarations = Enum.flat_map(plugins, & &1.declarations)

    invalid = Enum.reject(declarations, &valid_declaration?/1)

    diagnostics =
      Enum.map(invalid, fn declaration ->
        Diagnostic.new!(
          :invalid_declaration,
          "declaration metadata or ordered entries are invalid",
          source_for(declaration)
        )
      end)

    content_ids =
      declarations
      |> Enum.filter(&match?(%Declaration{role: :registered}, &1))
      |> duplicates_by(fn declaration ->
        Ref.canonical_id(%Ref{plugin_id: declaration.plugin_id, local_id: declaration.local_id})
      end)

    content_diagnostics =
      Enum.map(content_ids, fn id ->
        Diagnostic.new!(
          :duplicate_content_id,
          "block ID #{inspect(id)} is declared more than once",
          source_for(find_declaration_by_id(declarations, id))
        )
      end)

    modules = duplicates_by(declarations, & &1.module)

    module_diagnostics =
      Enum.map(modules, fn module ->
        Diagnostic.new!(
          :duplicate_declaration_module,
          "declaration module #{inspect(module)} is declared more than once",
          source_for(find_module_declaration(plugins, module))
        )
      end)

    diagnostics = diagnostics ++ content_diagnostics ++ module_diagnostics
    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp valid_declaration?(%Declaration{} = declaration) do
    valid_declaration_identity?(declaration) and valid_declaration_role?(declaration) and
      valid_declaration_entries?(declaration.entries)
  end

  defp valid_declaration?(_), do: false

  defp valid_declaration_identity?(declaration) do
    ModuleName.valid?(declaration.module) and Ref.valid_plugin_id?(declaration.plugin_id) and
      SourceLocation.valid?(declaration.source) and declaration.kind == :block
  end

  defp valid_declaration_role?(%Declaration{role: :template, local_id: nil}), do: true

  defp valid_declaration_role?(%Declaration{role: :registered, local_id: local_id}),
    do: Ref.valid_local_id?(local_id)

  defp valid_declaration_role?(_), do: false

  defp valid_declaration_entries?(entries) when is_list(entries),
    do: Enum.all?(entries, &valid_collected_entry?/1)

  defp valid_declaration_entries?(_), do: false

  defp normalize_collected_declaration(%Wyram.Plugin.DSL.CollectedDeclaration{} = raw, plugin) do
    if raw.plugin == plugin.entry and raw.plugin_id in [nil, plugin.id] do
      struct(Declaration,
        plugin_id: plugin.id,
        local_id: raw.local_id,
        module: raw.module,
        kind: raw.kind,
        role: raw.role,
        source: raw.source,
        entries: raw.entries
      )
    else
      raw
    end
  end

  defp normalize_collected_declaration(declaration, _plugin), do: declaration

  defp valid_collected_entry?(%Declaration.Template{} = entry),
    do: Declaration.Template.valid?(entry)

  defp valid_collected_entry?(%CapabilityContribution{} = entry),
    do: CapabilityContribution.valid?(entry)

  defp valid_collected_entry?(%Capability{} = capability) do
    ModuleName.valid?(capability.config_module) and is_boolean(capability.override) and
      SourceLocation.valid?(capability.source) and
      valid_struct_literal?(capability.config, capability.config_module)
  end

  defp valid_collected_entry?(_), do: false

  defp valid_struct_literal?(
         %StructLiteral{module: module, fields: fields},
         expected
       )
       when module == expected and is_map(fields) do
    ModuleName.valid?(module) and
      Enum.all?(fields, fn {key, value} -> is_atom(key) and valid_literal?(value) end)
  end

  defp valid_struct_literal?(_, _), do: false

  defp valid_literal?(%StructLiteral{module: module, fields: fields})
       when is_map(fields),
       do:
         ModuleName.valid?(module) and
           Enum.all?(fields, fn {key, value} -> is_atom(key) and valid_literal?(value) end)

  defp valid_literal?({:__wyram_module__, module}), do: ModuleName.valid?(module)

  defp valid_literal?(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_nil(value), do: true

  defp valid_literal?(value) when is_list(value), do: Enum.all?(value, &valid_literal?/1)

  defp valid_literal?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&valid_literal?/1)

  defp valid_literal?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> valid_literal?(key) and valid_literal?(item) end)

  defp valid_literal?(_), do: false

  defp validate_generated_modules(plugins) do
    declarations = Enum.flat_map(plugins, & &1.declarations)

    diagnostics = Enum.flat_map(declarations, &validate_generated_declaration(&1, plugins))

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp validate_generated_declaration(declaration, plugins) do
    owner = find_plugin(plugins, declaration.plugin_id)
    actual = generated_metadata(declaration.module)

    if valid_generated_owner?(owner, declaration, actual) and
         valid_generated_marker?(actual, expected_generated_metadata(owner, declaration)) and
         valid_generated_ref?(declaration) do
      []
    else
      [generated_module_diagnostic(declaration)]
    end
  end

  defp valid_generated_owner?(nil, _declaration, _actual), do: false

  defp valid_generated_owner?(owner, declaration, actual) do
    plugin_id = Map.get(actual || %{}, :plugin_id)

    (is_nil(plugin_id) or plugin_id == declaration.plugin_id) and
      declaration.plugin_id == owner.id
  end

  defp expected_generated_metadata(owner, declaration) do
    if owner do
      %{
        plugin: owner.entry,
        declaration_module: declaration.module,
        local_id: declaration.local_id,
        kind: declaration.kind,
        role: declaration.role,
        source: declaration.source
      }
    end
  end

  defp valid_generated_marker?(actual, expected) when is_map(actual) do
    Map.delete(actual, :plugin_id) == expected and
      Map.keys(actual) -- (Map.keys(expected || %{}) ++ [:plugin_id]) == []
  end

  defp valid_generated_marker?(_, _), do: false

  defp valid_generated_ref?(%Declaration{module: module, role: :registered}),
    do: function_exported?(module, :ref, 0)

  defp valid_generated_ref?(%Declaration{module: module, role: :template}),
    do: not function_exported?(module, :ref, 0)

  defp valid_generated_ref?(_), do: false

  defp generated_module_diagnostic(declaration) do
    Diagnostic.new!(
      :generated_module_mismatch,
      "generated declaration module #{inspect(declaration.module)} does not match collected ownership metadata",
      declaration.source
    )
  end

  defp generated_metadata(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, @generated_marker, 0) do
      case apply(module, @generated_marker, []) do
        metadata when is_map(metadata) -> metadata
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp validate_templates(plugins) do
    index = declaration_index(plugins)

    diagnostics =
      plugins
      |> Enum.flat_map(& &1.declarations)
      |> Enum.flat_map(fn declaration ->
        Enum.flat_map(
          declaration.entries,
          &validate_template_entry(&1, declaration, index, plugins)
        )
      end)

    cycles = template_cycles(plugins, index)
    diagnostics = diagnostics ++ cycles

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp validate_template_entry(%Template{} = template, declaration, index, plugins) do
    case Map.get(index, template.module) do
      nil ->
        [
          template_diagnostic(
            :unresolved_declaration,
            "template target #{inspect(template.module)} was not collected",
            template
          )
        ]

      target ->
        template_target_diagnostic(target, declaration, template, plugins)
    end
  end

  defp validate_template_entry(_entry, _declaration, _index, _plugins), do: []

  defp template_target_diagnostic(target, declaration, template, plugins) do
    cond do
      target.kind != declaration.kind ->
        [
          template_diagnostic(
            :wrong_reference_kind,
            "template target has the wrong declaration kind",
            template
          )
        ]

      target.role not in [:registered, :template] ->
        [
          template_diagnostic(
            :wrong_declaration_role,
            "template target is not eligible for block composition",
            template
          )
        ]

      not visible?(declaration.plugin_id, target.plugin_id, plugins) ->
        [
          template_diagnostic(
            :undeclared_dependency_reference,
            "template target belongs to a plugin that is not an explicit dependency",
            template
          )
        ]

      true ->
        []
    end
  end

  defp template_diagnostic(code, message, template) do
    Diagnostic.new!(code, message, template.source)
  end

  defp template_cycles(plugins, index) do
    declarations = Enum.flat_map(plugins, & &1.declarations)

    declarations
    |> Enum.reduce({MapSet.new(), []}, fn declaration, {visited, diagnostics} ->
      case find_template_cycle(declaration.module, index, [], visited) do
        {:ok, next_visited} ->
          {next_visited, diagnostics}

        {:cycle, cycle, next_visited} ->
          first = Map.fetch!(index, hd(cycle))
          related = Enum.map(Enum.drop(cycle, 1), &Map.fetch!(index, &1).source)

          diagnostic =
            Diagnostic.new!(
              :template_cycle,
              "template cycle: #{Enum.map_join(cycle, " -> ", &inspect/1)}",
              first.source,
              path: Enum.map(cycle, &inspect/1),
              related: related
            )

          {next_visited, [diagnostic | diagnostics]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp find_template_cycle(module, index, active, visited) do
    cond do
      module in active ->
        cycle = Enum.drop_while(active, &(&1 != module)) ++ [module]
        {:cycle, cycle, visited}

      MapSet.member?(visited, module) ->
        {:ok, visited}

      not Map.has_key?(index, module) ->
        {:ok, MapSet.put(visited, module)}

      true ->
        declaration = Map.fetch!(index, module)
        targets = for %Declaration.Template{module: target} <- declaration.entries, do: target

        visit_template_targets(targets, index, module, active, MapSet.put(visited, module))
    end
  end

  defp visit_template_targets(targets, index, module, active, visited) do
    Enum.reduce_while(targets, {:ok, visited}, fn target, {:ok, seen} ->
      case find_template_cycle(target, index, active ++ [module], seen) do
        {:ok, next_seen} -> {:cont, {:ok, next_seen}}
        {:cycle, cycle, next_seen} -> {:halt, {:cycle, cycle, next_seen}}
      end
    end)
  end

  defp expand_declarations(plugins, candidates, budget) do
    declarations =
      plugins
      |> Enum.flat_map(& &1.declarations)
      |> Enum.sort_by(&inspect(&1.module))

    index = declaration_index(plugins)

    Enum.reduce_while(declarations, {:ok, %{}, 0}, fn declaration, {:ok, acc, total_used} ->
      case compose_declaration(declaration, index, candidates, [], budget - total_used) do
        {:ok, compiled, used} when total_used + used <= budget ->
          {:cont, {:ok, Map.put(acc, declaration.module, compiled), total_used + used}}

        {:ok, _compiled, _used} ->
          {:halt,
           {:error,
            Diagnostic.new!(
              :template_expansion_budget_exceeded,
              "compiled catalog exceeds the configured template expansion budget",
              declaration.source
            )}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, expanded, _used} -> {:ok, expanded}
      error -> error
    end
  end

  defp compose_declaration(declaration, index, candidates, active, budget) do
    if declaration.module in active do
      {:error, composition_cycle_diagnostic(declaration, active)}
    else
      compose_declaration_entries(declaration, index, candidates, active, budget)
    end
  end

  defp composition_cycle_diagnostic(declaration, active) do
    Diagnostic.new!(
      :template_cycle,
      "template cycle detected during composition",
      declaration.source,
      path: Enum.map(active ++ [declaration.module], &inspect/1)
    )
  end

  defp compose_declaration_entries(declaration, index, candidates, active, budget) do
    provider_set = Map.fetch!(candidates, declaration.plugin_id)

    with {:ok, authored, used} <-
           compose_ordered_entries(declaration, index, candidates, provider_set, active, budget),
         {:ok, _authored_descriptor} <- lower_descriptor(authored, provider_set, declaration),
         {:ok, completed, descriptor} <-
           maybe_complete_registered(authored, provider_set, declaration) do
      {:ok, %{authored: authored, entries: completed, descriptor: descriptor}, used}
    end
  end

  defp compose_ordered_entries(declaration, index, candidates, provider_set, active, budget) do
    Enum.reduce_while(declaration.entries, {:ok, [], 0}, fn entry, {:ok, composed, used} ->
      context = %{
        composed: composed,
        used: used,
        declaration: declaration,
        index: index,
        candidates: candidates,
        provider_set: provider_set,
        active: active,
        budget: budget
      }

      case compose_entry(entry, context) do
        {:ok, next, next_used} -> {:cont, {:ok, next, next_used}}
        error -> {:halt, error}
      end
    end)
  end

  defp compose_entry(%Template{module: module, source: source}, context) do
    %{
      composed: composed,
      used: used,
      declaration: declaration,
      index: index,
      provider_set: provider_set,
      budget: budget
    } = context

    target = Map.fetch!(index, module)

    with :ok <- within_template_budget(used, 0, budget, source),
         {:ok, inherited_compiled, nested_used} <-
           compose_declaration(
             target,
             context.index,
             context.candidates,
             context.active ++ [declaration.module],
             budget - used - 1
           ),
         :ok <- within_template_budget(used, nested_used, budget, source),
         inherited <- template_contributions(inherited_compiled.authored),
         {:ok, next} <- compose_entries(composed, inherited, provider_set, declaration.kind) do
      {:ok, next, used + nested_used + 1}
    end
  end

  defp compose_entry(%CapabilityContribution{} = contribution, context) do
    %{composed: composed, used: used, declaration: declaration, provider_set: provider_set} =
      context

    with {:ok, next} <- compose_entries(composed, [contribution], provider_set, declaration.kind),
         do: {:ok, next, used}
  end

  defp compose_entry(%Capability{} = capability, context) do
    %{composed: composed, used: used, declaration: declaration, provider_set: provider_set} =
      context

    with {:ok, contribution} <- materialize_capability(capability, provider_set),
         {:ok, next} <- compose_entries(composed, [contribution], provider_set, declaration.kind),
         do: {:ok, next, used}
  end

  defp compose_entry(_entry, %{declaration: declaration}) do
    {:error,
     Diagnostic.new!(
       :invalid_declaration_entry,
       "unsupported compiled declaration entry",
       declaration.source
     )}
  end

  defp within_template_budget(used, nested_used, budget, source) do
    if used + nested_used + 1 > budget, do: {:error, expansion_budget_error(source)}, else: :ok
  end

  defp template_contributions(authored) do
    Enum.map(authored, &%{&1 | origin: :template, override: false})
  end

  defp maybe_complete_registered(authored, _provider_set, %{role: :template}),
    do: {:ok, authored, %{}}

  defp maybe_complete_registered(authored, provider_set, declaration) do
    with {:ok, completed} <- add_defaults(authored, provider_set, declaration),
         {:ok, descriptor} <- lower_descriptor(completed, provider_set, declaration) do
      {:ok, completed, descriptor}
    end
  end

  defp materialize_capability(capability, candidates) do
    with {:ok, provider} <- Provider.for_config(capability.config_module, candidates),
         {:ok, config} <- materialize_config(capability.config, capability.config_module),
         {:ok, contribution} <-
           {:ok,
            CapabilityContribution.new!(provider, config, capability.source,
              override: capability.override,
              origin: :authored
            )} do
      {:ok, contribution}
    else
      {:error, reason} ->
        {:error,
         Diagnostic.new!(
           :invalid_capability,
           "cannot materialize capability: #{inspect(reason)}",
           capability.source
         )}
    end
  rescue
    _ ->
      {:error,
       Diagnostic.new!(
         :invalid_capability,
         "cannot materialize capability config",
         capability.source
       )}
  end

  defp materialize_config(
         %Wyram.Plugin.DSL.StructLiteral{module: module, fields: fields},
         expected
       )
       when module == expected and is_map(fields) do
    {:ok,
     struct(expected, Map.new(fields, fn {key, value} -> {key, materialize_literal(value)} end))}
  rescue
    _ -> :error
  end

  defp materialize_config(config, expected) when is_map(config) do
    if Map.get(config, :__struct__) == expected, do: {:ok, config}, else: :error
  end

  defp materialize_config(_config, _expected), do: :error

  defp materialize_literal(%Wyram.Plugin.DSL.StructLiteral{module: module, fields: fields}),
    do: struct!(module, Map.new(fields, fn {key, value} -> {key, materialize_literal(value)} end))

  defp materialize_literal({:__wyram_module__, module}) when is_atom(module), do: module
  defp materialize_literal(value) when is_list(value), do: Enum.map(value, &materialize_literal/1)

  defp materialize_literal(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&materialize_literal/1) |> List.to_tuple()

  defp materialize_literal(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, materialize_literal(item)} end)

  defp materialize_literal(value), do: value

  defp expansion_budget_error(source) do
    Diagnostic.new!(
      :template_expansion_budget_exceeded,
      "block template expansion exceeds the configured budget",
      source
    )
  end

  defp compose_entries(current, additions, candidates, kind) do
    Enum.reduce_while(additions, {:ok, current}, fn contribution, {:ok, composed} ->
      with {:ok, provider} <- resolve_provider(contribution, candidates),
           :ok <- validate_contribution(contribution, provider, kind),
           {:ok, updated} <- apply_contribution(composed, %{contribution | provider: provider}) do
        {:cont, {:ok, updated}}
      else
        {:error, %Diagnostic{} = diagnostic} ->
          {:halt, {:error, diagnostic}}

        {:error, diagnostics} when is_list(diagnostics) ->
          {:halt, {:error, diagnostics}}

        {:error, reason} ->
          {:halt,
           {:error,
            Diagnostic.new!(
              :invalid_provider,
              "cannot resolve provider #{inspect(contribution.provider)}: #{inspect(reason)}",
              contribution.source
            )}}
      end
    end)
  end

  defp resolve_provider(%CapabilityContribution{provider: provider} = contribution, candidates) do
    case Enum.find(candidates, fn candidate ->
           candidate == provider and valid_provider_candidate?(candidate, candidates)
         end) do
      nil ->
        {:error,
         Diagnostic.new!(
           :unknown_provider,
           "provider #{inspect(provider)} is not available through this plugin or an explicit dependency",
           contribution.source
         )}

      provider ->
        {:ok, provider}
    end
  end

  defp validate_contribution(contribution, provider, kind) do
    config_module = provider.config_module()
    config_struct = Map.get(contribution.config, :__struct__)

    cond do
      kind not in provider.kinds() ->
        {:error,
         Diagnostic.new!(
           :provider_kind_mismatch,
           "provider #{inspect(provider)} does not support #{inspect(kind)} declarations",
           contribution.source
         )}

      not is_nil(config_struct) and config_struct != config_module ->
        {:error,
         Diagnostic.new!(
           :provider_config_mismatch,
           "provider #{inspect(provider)} expects #{inspect(config_module)}, received #{inspect(config_struct)}",
           contribution.source
         )}

      true ->
        run_provider(provider, :validate, contribution.config, contribution.source)
    end
  rescue
    error ->
      {:error,
       Diagnostic.new!(
         :provider_validation_failed,
         "provider validation failed: #{Exception.message(error)}",
         contribution.source
       )}
  end

  defp run_provider(provider, function, config, source) do
    case apply(provider, function, [config, %{source: source}]) do
      :ok when function == :validate ->
        :ok

      {:ok, result} when function == :lower and is_map(result) ->
        {:ok, result}

      {:error, diagnostics} when is_list(diagnostics) and diagnostics != [] ->
        if Enum.all?(diagnostics, &match?(%Diagnostic{}, &1)),
          do: {:error, diagnostics},
          else: invalid_provider_result(provider, function, source)

      _ ->
        invalid_provider_result(provider, function, source)
    end
  rescue
    error ->
      {:error,
       provider_execution_diagnostic(provider, function, source, Exception.message(error))}
  catch
    kind, reason ->
      {:error,
       provider_execution_diagnostic(provider, function, source, "#{kind}: #{inspect(reason)}")}
  end

  defp provider_execution_diagnostic(provider, function, source, reason) do
    Diagnostic.new!(
      :provider_execution_failed,
      "provider #{inspect(provider)} #{function}/2 failed: #{reason}",
      source
    )
  end

  defp invalid_provider_result(provider, function, source) do
    {:error,
     Diagnostic.new!(
       :invalid_provider_result,
       "provider #{inspect(provider)} returned an invalid result from #{function}/2",
       source
     )}
  end

  defp apply_contribution(composed, contribution) do
    previous = Enum.find(composed, &(&1.provider == contribution.provider))

    cond do
      contribution.override and is_nil(previous) ->
        {:error,
         Diagnostic.new!(
           :missing_override_target,
           "override for #{inspect(contribution.provider)} has no prior authored contribution",
           contribution.source
         )}

      contribution.override ->
        {:ok,
         Enum.map(composed, fn current ->
           if current.provider == contribution.provider,
             do: %{contribution | override: false},
             else: current
         end)}

      previous ->
        {:error,
         Diagnostic.new!(
           :duplicate_provider,
           "provider #{inspect(contribution.provider)} is contributed more than once without override: true",
           contribution.source,
           related: [previous.source]
         )}

      true ->
        {:ok, composed ++ [contribution]}
    end
  end

  defp add_defaults(authored, candidates, declaration) do
    default_entries = BlockDefaults.entries(declaration.source)
    authored_fields = owned_fields(authored)

    defaults =
      Enum.reject(default_entries, fn default ->
        provider = Enum.find(candidates, &(&1 == default.provider))

        not is_nil(provider) and
          Enum.any?(Map.keys(provider.owned_fields()), &MapSet.member?(authored_fields, &1))
      end)

    compose_entries(authored, defaults, candidates, declaration.kind)
  end

  defp owned_fields(contributions) do
    Enum.reduce(contributions, MapSet.new(), fn contribution, fields ->
      MapSet.union(fields, MapSet.new(Map.keys(contribution.provider.owned_fields())))
    end)
  end

  defp lower_descriptor(contributions, _candidates, _declaration) do
    conflicts = Provider.ownership_conflicts(Enum.map(contributions, & &1.provider))

    if conflicts != [] do
      {:error, field_conflict_diagnostic(hd(conflicts), contributions)}
    else
      lower_contributions(contributions)
    end
  end

  defp field_conflict_diagnostic(conflict, contributions) do
    owners = conflict.providers
    second = Enum.find(contributions, &(&1.provider == List.last(owners)))
    first = Enum.find(contributions, &(&1.provider == hd(owners)))

    Diagnostic.new!(
      :descriptor_field_conflict,
      "providers #{inspect(owners)} both own descriptor field #{inspect(conflict.field)}",
      second.source,
      related: [first.source]
    )
  end

  defp lower_contributions(contributions) do
    Enum.reduce_while(contributions, {:ok, %{}}, fn contribution, {:ok, descriptor} ->
      lower_contribution(contribution, descriptor)
    end)
    |> case do
      {:ok, descriptor} -> {:ok, descriptor}
      error -> error
    end
  end

  defp lower_contribution(contribution, descriptor) do
    with {:ok, fields} <-
           run_provider(
             contribution.provider,
             :lower,
             contribution.config,
             contribution.source
           ),
         :ok <- validate_lowered_fields(contribution.provider, fields, contribution.source) do
      {:cont, {:ok, Map.merge(descriptor, fields)}}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:halt, {:error, diagnostic}}
      {:error, diagnostics} when is_list(diagnostics) -> {:halt, {:error, diagnostics}}
    end
  end

  defp validate_lowered_fields(provider, fields, source) do
    owned = Map.keys(provider.owned_fields()) |> Enum.sort()
    keys = Map.keys(fields) |> Enum.sort()
    unsupported = keys -- [:geometry, :collision, :material]

    cond do
      keys != owned ->
        {:error,
         Diagnostic.new!(
           :invalid_provider_output,
           "provider #{inspect(provider)} lowered fields #{inspect(keys)} but owns #{inspect(owned)}",
           source
         )}

      unsupported != [] ->
        {:error,
         Diagnostic.new!(
           :unsupported_descriptor_field,
           "descriptor fields are not supported by this backend: #{inspect(unsupported)}",
           source
         )}

      Enum.any?(fields, fn {field, value} -> not valid_backend_field?(field, value) end) ->
        {:error,
         Diagnostic.new!(
           :unsupported_descriptor_value,
           "provider #{inspect(provider)} lowered a descriptor value unsupported by this backend",
           source
         )}

      true ->
        :ok
    end
  end

  defp valid_backend_field?(:geometry, %{primitive: :cube} = value),
    do: Map.keys(value) == [:primitive]

  defp valid_backend_field?(:collision, %{primitive: :cube} = value),
    do: Map.keys(value) == [:primitive]

  defp valid_backend_field?(:material, %{color: {r, g, b}, mode: :opaque} = value) do
    Map.keys(value) |> Enum.sort() == [:color, :mode] and
      Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255))
  end

  defp valid_backend_field?(_, _), do: false

  defp build_result(plugins, order, expanded) do
    by_id = Map.new(plugins, &{&1.id, &1})
    index = declaration_index(plugins)

    catalogs =
      Map.new(plugins, fn plugin ->
        blocks =
          plugin.declarations
          |> Enum.filter(&(&1.role == :registered))
          |> Enum.sort_by(&Ref.canonical_id(%Ref{plugin_id: &1.plugin_id, local_id: &1.local_id}))
          |> Enum.map(fn declaration ->
            %{
              id:
                Ref.canonical_id(%Ref{
                  plugin_id: declaration.plugin_id,
                  local_id: declaration.local_id
                }),
              plugin_id: declaration.plugin_id,
              local_id: declaration.local_id,
              module: declaration.module,
              kind: declaration.kind,
              descriptor: expanded[declaration.module].descriptor,
              entries: expanded[declaration.module].entries,
              source: declaration.source
            }
          end)

        {plugin.id,
         %{
           id: plugin.id,
           entry: plugin.entry,
           dependencies: Enum.sort(plugin.dependencies),
           providers: Enum.sort_by(plugin.providers, &inspect/1),
           modules: Enum.sort_by(plugin.modules, &inspect/1),
           module_hashes: Map.get(plugin, :module_hashes, %{}),
           game: plugin.game,
           blocks: blocks
         }}
      end)

    interfaces =
      Map.new(plugins, fn plugin ->
        direct = Enum.map(plugin.dependencies, &by_id[&1])
        closure = dependency_closure(direct, by_id, %{})

        {plugin.id,
         %{
           id: plugin.id,
           entry: plugin.entry,
           dependencies: Enum.sort(plugin.dependencies),
           declarations:
             Enum.filter(plugin.declarations, &(&1.role == :registered or &1.role == :template)),
           providers: plugin.providers,
           modules: plugin.modules,
           module_hashes: Map.get(plugin, :module_hashes, %{}),
           game: plugin.game,
           plugins: [plugin | closure],
           symbols: index
         }}
      end)

    %{order: order, catalogs: catalogs, interfaces: interfaces}
  end

  @spec dependency_closure(
          [plugin_input()],
          %{String.t() => plugin_input()},
          %{optional(String.t()) => true}
        ) :: [plugin_input()]
  defp dependency_closure([], _by_id, _seen), do: []

  defp dependency_closure([plugin | rest], by_id, seen) do
    if Map.has_key?(seen, plugin.id) do
      dependency_closure(rest, by_id, seen)
    else
      next_seen = Map.put(seen, plugin.id, true)
      children = Enum.map(plugin.dependencies, &by_id[&1])
      [plugin | dependency_closure(children ++ rest, by_id, next_seen)]
    end
  end

  defp visible?(owner_id, target_id, _plugins) when owner_id == target_id, do: true

  defp visible?(owner_id, target_id, plugins) do
    case find_plugin(plugins, owner_id) do
      nil -> false
      owner -> target_id in owner.dependencies
    end
  end

  defp declaration_index(plugins) do
    plugins
    |> Enum.flat_map(& &1.declarations)
    |> Map.new(&{&1.module, &1})
  end

  defp duplicates_by(list, key_fun), do: list |> Enum.map(key_fun) |> duplicates()

  defp duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&inspect/1)
  end

  defp find_plugin(plugins, id), do: Enum.find(plugins, &(&1.id == id))

  defp find_module_declaration(plugins, module) do
    Enum.find_value(plugins, fn plugin ->
      Enum.find(plugin.declarations, &(&1.module == module))
    end)
  end

  defp find_declaration_by_id(declarations, id) do
    Enum.find(declarations, fn
      %Declaration{role: :registered} = declaration ->
        Ref.canonical_id(%Ref{plugin_id: declaration.plugin_id, local_id: declaration.local_id}) ==
          id

      _ ->
        false
    end)
  end

  defp source_for(%{source: %SourceLocation{} = source}), do: source

  defp source_for(%{entry: entry}) when is_atom(entry),
    do: %SourceLocation{file: "mix.exs", line: 1, module: entry}

  defp source_for(_), do: %SourceLocation{file: "mix.exs", line: 1}

  defp hd_or_nil([value | _]), do: value
  defp hd_or_nil(_), do: nil
end
