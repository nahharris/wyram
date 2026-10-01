defmodule Wyram.Plugin.Linker do
  @moduledoc "Links collected plugin declarations into deterministic logical catalogs."

  alias Wyram.Block.Ref
  alias Wyram.Plugin.{Declaration, Diagnostic, SourceLocation}

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

    with :ok <- validate_options(budget),
         {:ok, normalized} <- normalize_plugins(plugins),
         :ok <- unique_plugin_ids(normalized),
         :ok <- unique_owned_modules(normalized),
         :ok <- validate_dependencies(normalized),
         {:ok, order} <- dependency_order(normalized),
         :ok <- unique_declarations(normalized),
         :ok <- validate_generated_modules(normalized),
         :ok <- validate_templates(normalized),
         {:ok, expanded} <- expand_declarations(normalized, budget) do
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

    missing =
      Enum.filter(required, fn dependency ->
        not Map.has_key?(dependency_interfaces, dependency)
      end)

    if missing != [] do
      {:error,
       Enum.map(missing, fn dependency ->
         Diagnostic.new!(
           :missing_dependency,
           "required plugin dependency #{inspect(dependency)} has no compiled interface",
           source_for(metadata)
         )
       end)}
    else
      dependencies =
        required
        |> Enum.flat_map(fn dependency ->
          interface = Map.fetch!(dependency_interfaces, dependency)

          case Map.fetch(interface, :plugins) do
            {:ok, plugins} when is_list(plugins) -> plugins
            _ -> [Map.fetch!(interface, :plugin)]
          end
        end)
        |> Enum.uniq_by(& &1.id)

      current = Map.merge(metadata, %{declarations: declarations})

      with {:ok, linked} <- link_set(dependencies ++ [current], options) do
        id = Map.fetch!(metadata, :id)

        {:ok,
         %{catalog: Map.fetch!(linked.catalogs, id), interface: Map.fetch!(linked.interfaces, id)}}
      end
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

  defp validate_options(budget) when is_integer(budget) and budget > 0, do: :ok

  defp validate_options(_budget),
    do:
      {:error,
       Diagnostic.new!(
         :invalid_expansion_budget,
         "template expansion budget must be positive",
         source_for(nil)
       )}

  defp normalize_plugins(plugins) do
    if Enum.all?(plugins, &valid_plugin_input?/1) do
      normalized =
        plugins
        |> Enum.map(fn plugin ->
          Map.merge(
            %{providers: [], modules: [], game: nil},
            plugin
          )
        end)
        |> Enum.sort_by(& &1.id)

      {:ok, normalized}
    else
      {:error,
       Diagnostic.new!(
         :invalid_link_input,
         "each plugin needs an ID, entry module, dependency list, and declaration list",
         source_for(hd_or_nil(plugins))
       )}
    end
  end

  defp valid_plugin_input?(plugin) when is_map(plugin) do
    Ref.valid_plugin_id?(Map.get(plugin, :id)) and is_atom(Map.get(plugin, :entry)) and
      is_list(Map.get(plugin, :dependencies)) and is_list(Map.get(plugin, :declarations)) and
      is_list(Map.get(plugin, :providers, [])) and is_list(Map.get(plugin, :modules, [])) and
      Enum.all?(Map.get(plugin, :dependencies), &Ref.valid_plugin_id?/1) and
      Enum.all?(Map.get(plugin, :providers, []), &is_atom/1) and
      Enum.all?(Map.get(plugin, :modules, []), &is_atom/1)
  end

  defp valid_plugin_input?(_), do: false

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
                    source_for(plugin), path: [plugin.id, plugin.id])
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

        Enum.reduce_while(Enum.sort(plugin.dependencies), {:ok, complete, order}, fn dependency,
                                                                                     {:ok, seen,
                                                                                      acc} ->
          case visit_plugin(dependency, by_id, seen, active ++ [id], acc) do
            {:ok, next_seen, next_acc} -> {:cont, {:ok, next_seen, next_acc}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, seen, acc} ->
            if MapSet.member?(seen, id) do
              {:ok, seen, acc}
            else
              {:ok, MapSet.put(seen, id), [id | acc]}
            end

          error ->
            error
        end
    end
  end

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
    Ref.valid_plugin_id?(declaration.plugin_id) and is_atom(declaration.module) and
      declaration.kind == :block and declaration.role in [:registered, :template] and
      match?(
        %SourceLocation{file: file, line: line}
        when is_binary(file) and is_integer(line) and line > 0,
        declaration.source
      ) and
      is_list(declaration.entries) and
      ((declaration.role == :registered and Ref.valid_local_id?(declaration.local_id)) or
         (declaration.role == :template and
            (is_nil(declaration.local_id) or Ref.valid_local_id?(declaration.local_id)))) and
      Enum.all?(declaration.entries, &valid_entry?/1)
  end

  defp valid_declaration?(_), do: false

  defp valid_entry?(%Declaration.Template{module: module, source: source}) do
    is_atom(module) and valid_source?(source)
  end

  defp valid_entry?(%Wyram.Plugin.CapabilityContribution{
         provider: provider,
         config: config,
         source: source,
         override: override,
         origin: origin
       }) do
    is_atom(provider) and is_map(config) and valid_source?(source) and is_boolean(override) and
      origin in [:authored, :template, :default]
  end

  defp valid_entry?(_), do: false

  defp valid_source?(%SourceLocation{file: file, line: line, column: column, module: module}) do
    is_binary(file) and String.valid?(file) and is_integer(line) and line > 0 and
      (is_nil(column) or (is_integer(column) and column > 0)) and
      (is_nil(module) or is_atom(module))
  end

  defp valid_source?(_), do: false

  defp validate_generated_modules(plugins) do
    declarations = Enum.flat_map(plugins, & &1.declarations)

    diagnostics =
      Enum.flat_map(declarations, fn declaration ->
        owner = find_plugin(plugins, declaration.plugin_id)

        expected =
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

        actual = generated_metadata(declaration.module)

        valid_owner =
          owner != nil and
            (is_nil(Map.get(actual || %{}, :plugin_id)) or
               Map.get(actual || %{}, :plugin_id) == declaration.plugin_id) and
            declaration.plugin_id == owner.id

        valid_marker =
          is_map(actual) and Map.take(actual, Map.keys(expected || %{})) == expected

        valid_ref =
          case declaration.role do
            :registered -> function_exported?(declaration.module, :ref, 0)
            :template -> not function_exported?(declaration.module, :ref, 0)
          end

        if valid_owner and valid_marker and valid_ref do
          []
        else
          [
            Diagnostic.new!(
              :generated_module_mismatch,
              "generated declaration module #{inspect(declaration.module)} does not match collected ownership metadata",
              declaration.source
            )
          ]
        end
      end)

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
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
      Enum.flat_map(Enum.flat_map(plugins, & &1.declarations), fn declaration ->
        Enum.flat_map(declaration.entries, fn
          %Declaration.Template{} = template ->
            case Map.get(index, template.module) do
              nil ->
                [
                  Diagnostic.new!(
                    :unresolved_declaration,
                    "template target #{inspect(template.module)} was not collected",
                    template.source
                  )
                ]

              target ->
                cond do
                  target.kind != declaration.kind ->
                    [
                      Diagnostic.new!(
                        :wrong_reference_kind,
                        "template target has the wrong declaration kind",
                        template.source
                      )
                    ]

                  target.role not in [:registered, :template] ->
                    [
                      Diagnostic.new!(
                        :wrong_declaration_role,
                        "template target is not eligible for block composition",
                        template.source
                      )
                    ]

                  not visible?(declaration.plugin_id, target.plugin_id, plugins) ->
                    [
                      Diagnostic.new!(
                        :undeclared_dependency_reference,
                        "template target belongs to a plugin that is not an explicit dependency",
                        template.source
                      )
                    ]

                  true ->
                    []
                end
            end

          _ ->
            []
        end)
      end)

    cycles = template_cycles(plugins, index)
    diagnostics = diagnostics ++ cycles

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
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

        Enum.reduce_while(targets, {:ok, MapSet.put(visited, module)}, fn target, {:ok, seen} ->
          case find_template_cycle(target, index, active ++ [module], seen) do
            {:ok, next_seen} -> {:cont, {:ok, next_seen}}
            {:cycle, cycle, next_seen} -> {:halt, {:cycle, cycle, next_seen}}
          end
        end)
    end
  end

  defp expand_declarations(plugins, budget) do
    declarations = Enum.flat_map(plugins, & &1.declarations)
    index = declaration_index(plugins)
    templates = Enum.filter(declarations, &(&1.role == :template))

    if length(templates) > budget do
      declaration = hd(templates)

      {:error,
       Diagnostic.new!(
         :template_expansion_budget_exceeded,
         "template declaration count exceeds the configured expansion budget",
         declaration.source
       )}
    else
      blocks = Enum.filter(declarations, &(&1.role == :registered))

      Enum.reduce_while(blocks, {:ok, %{}}, fn declaration, {:ok, acc} ->
        case expand_one(declaration, index, [], budget) do
          {:ok, entries, used} when used <= budget ->
            {:cont, {:ok, Map.put(acc, declaration.module, entries)}}

          {:ok, _entries, _used} ->
            {:halt,
             {:error,
              Diagnostic.new!(
                :template_expansion_budget_exceeded,
                "block template expansion exceeds the configured budget",
                declaration.source
              )}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp expand_one(declaration, index, active, budget) do
    if declaration.module in active do
      {:error,
       Diagnostic.new!(
         :template_cycle,
         "template cycle detected during expansion",
         declaration.source,
         path: Enum.map(active ++ [declaration.module], &inspect/1)
       )}
    else
      Enum.reduce_while(declaration.entries, {:ok, [], 0}, fn
        %Declaration.Template{module: module}, {:ok, entries, used} ->
          case Map.get(index, module) do
            nil ->
              {:halt,
               {:error,
                Diagnostic.new!(
                  :unresolved_declaration,
                  "template target #{inspect(module)} was not collected",
                  declaration.source
                )}}

            target ->
              case expand_one(target, index, active ++ [declaration.module], budget) do
                {:ok, inherited, count} ->
                  if used + count + 1 <= budget do
                    {:cont, {:ok, entries ++ inherited, used + count + 1}}
                  else
                    {:halt,
                     {:error,
                      Diagnostic.new!(
                        :template_expansion_budget_exceeded,
                        "block template expansion exceeds the configured budget",
                        declaration.source
                      )}}
                  end

                error ->
                  {:halt, error}
              end
          end

        entry, {:ok, entries, used} ->
          {:cont, {:ok, entries ++ [entry], used}}
      end)
    end
  end

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
              descriptor: %{},
              entries: Map.get(expanded, declaration.module, declaration.entries),
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
           game: plugin.game,
           blocks: blocks
         }}
      end)

    interfaces =
      Map.new(plugins, fn plugin ->
        direct = Enum.map(plugin.dependencies, &by_id[&1])
        closure = dependency_closure(direct, by_id, MapSet.new())

        {plugin.id,
         %{
           id: plugin.id,
           entry: plugin.entry,
           dependencies: Enum.sort(plugin.dependencies),
           declarations:
             Enum.filter(plugin.declarations, &(&1.role == :registered or &1.role == :template)),
           providers: plugin.providers,
           modules: plugin.modules,
           game: plugin.game,
           plugins: [plugin | closure],
           symbols: index
         }}
      end)

    %{order: order, catalogs: catalogs, interfaces: interfaces}
  end

  defp dependency_closure([], _by_id, _seen), do: []

  defp dependency_closure([plugin | rest], by_id, seen) do
    if MapSet.member?(seen, plugin.id) do
      dependency_closure(rest, by_id, seen)
    else
      next_seen = MapSet.put(seen, plugin.id)
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
