defmodule Wyram.Plugin.ContentCompiler do
  @moduledoc false
  alias Wyram.Block.Ref
  alias Wyram.Character.{Definition, Model, Profile}
  alias Wyram.Plugin.{Content, Diagnostic}
  alias Wyram.Plugin.DSL.StructLiteral
  alias Wyram.WorldGen.{Biome, Carver, Config, Feature, Field, Islands, Terrain}

  @schemas [Feature, Field, Carver, Islands, Terrain]
  @block_fields [:surface, :soil, :rock, :water, :block, :accent]

  def compile(plugin, declarations, catalog, dependencies) do
    with :ok <- unique(declarations), :ok <- validate_members(declarations, plugin) do
      state = %{plugin: plugin, index: index(catalog, dependencies), compiled: %{}, authored: %{}}

      authored =
        Map.new(declarations, &{Atom.to_string(&1.module), Map.put(&1, :plugin_id, plugin.id)})

      state = %{state | authored: authored}

      state =
        Enum.reduce(Enum.sort(Map.keys(authored)), state, fn name, state ->
          {_record, state} = lower(name, state, [])
          state
        end)

      {:ok, state.compiled |> Map.values() |> Enum.sort_by(&{&1.kind, &1.id})}
    end
  catch
    {:content_error, diagnostic} -> {:error, diagnostic}
  end

  def index(catalog, dependencies) do
    dependencies =
      Enum.flat_map(dependencies, fn {_id, %{plugin: interface}} ->
        Enum.flat_map(interface.plugins, fn owner ->
          blocks = Enum.filter(owner.declarations, &(&1.role == :registered))
          Enum.map(blocks, &block_record/1) ++ Map.get(owner, :compiled_content, [])
        end)
      end)

    own = Enum.map(catalog.blocks, &block_record/1) ++ Map.get(catalog, :content, [])
    Map.new(dependencies ++ own, &{module_name(&1.module), &1})
  end

  def select(module, kind, plugin, index, source) do
    name = module_name(module)

    case Map.fetch(index, name) do
      {:ok, record} ->
        check_reference!(record, kind, plugin, source)

      :error ->
        fail(:unresolved_content_reference, "unresolved #{kind} reference #{name}", source)
    end
  end

  defp unique(declarations) do
    modules =
      Enum.frequencies_by(declarations, & &1.module)
      |> Enum.find(fn {_key, count} -> count > 1 end)

    repeated =
      declarations
      |> Enum.frequencies_by(&{&1.kind, &1.local_id})
      |> Enum.find(fn {_key, count} -> count > 1 end)

    case {modules, repeated} do
      {{module, _}, _} ->
        declaration = Enum.find(declarations, &(&1.module == module))

        {:error,
         Diagnostic.new!(
           :duplicate_content_module,
           "duplicate content module #{inspect(module)}",
           declaration.source
         )}

      {nil, {{kind, id}, _}} ->
        declaration = Enum.find(declarations, &(&1.kind == kind and &1.local_id == id))

        {:error,
         Diagnostic.new!(
           :duplicate_content_id,
           "duplicate #{kind} id #{inspect(id)}",
           declaration.source
         )}

      {nil, nil} ->
        :ok
    end
  end

  defp validate_members(declarations, plugin) do
    Enum.each(declarations, fn declaration ->
      unless declaration.module in plugin.modules,
        do:
          fail(
            :module_ownership_mismatch,
            "generated content module is outside this compiled application",
            declaration.source
          )

      expected = Map.take(declaration, [:plugin, :module, :kind, :local_id])

      unless Code.ensure_loaded?(declaration.module) and
               function_exported?(declaration.module, :__wyram_content__, 0) and
               declaration.module.__wyram_content__() == expected,
             do:
               fail(
                 :content_marker_mismatch,
                 "generated content module does not match its declaration",
                 declaration.source
               )
    end)

    :ok
  end

  defp lower(name, state, active) do
    cond do
      Map.has_key?(state.compiled, name) ->
        {state.compiled[name], state}

      Map.has_key?(state.index, name) ->
        {state.index[name], state}

      name in active ->
        fail(
          :content_reference_cycle,
          "content reference cycle at #{name}",
          state.authored[name].source
        )

      true ->
        lower_authored(name, state, active)
    end
  end

  defp lower_authored(name, state, active) do
    declaration = state.authored[name]

    {fields, state, references} =
      materialize(declaration.data, state, [name | active], declaration.source)

    data = build(declaration, fields, state.plugin)

    record = %{
      id: state.plugin.id <> ":" <> declaration.local_id,
      plugin_id: state.plugin.id,
      local_id: declaration.local_id,
      module: name,
      kind: declaration.kind,
      data: data,
      references: Enum.uniq(references)
    }

    unless Content.valid_record?(record),
      do:
        fail(
          :invalid_content_configuration,
          "invalid compiled #{declaration.kind} configuration",
          declaration.source
        )

    {record, %{state | compiled: Map.put(state.compiled, name, record)}}
  rescue
    error ->
      declaration = state.authored[name]

      fail(
        :invalid_content_configuration,
        "invalid #{declaration.kind} #{name}: #{Exception.message(error)}",
        declaration.source
      )
  end

  defp materialize(%StructLiteral{module: module, fields: fields}, state, active, source) do
    unless module in @schemas,
      do:
        fail(
          :invalid_content_configuration,
          "unsupported configuration struct #{inspect(module)}",
          source
        )

    {fields, state, references} = materialize(fields, state, active, source)
    {module.new!(fields), state, references}
  end

  defp materialize(value, state, active, source) when is_map(value) do
    Enum.reduce(value, {%{}, state, []}, fn {key, value}, {values, state, refs} ->
      {value, state, more} = field(key, value, state, active, source)
      {Map.put(values, key, value), state, refs ++ more}
    end)
  end

  defp materialize(values, state, active, source) when is_list(values) do
    Enum.reduce(values, {[], state, []}, fn value, {values, state, refs} ->
      {value, state, more} = materialize(value, state, active, source)
      {values ++ [value], state, refs ++ more}
    end)
  end

  defp materialize({:__wyram_module__, module}, _state, _active, source),
    do:
      fail(
        :content_reference_kind_mismatch,
        "module #{inspect(module)} is not valid in this field",
        source
      )

  defp materialize(value, state, _active, _source), do: {value, state, []}

  defp field(key, {:__wyram_module__, module}, state, active, source) do
    reference(module, expected_kind(key, source), state, active, source)
  end

  defp field(:biomes, values, state, active, source) when is_list(values) do
    Enum.reduce(values, {[], state, []}, fn
      {:__wyram_module__, module}, {values, state, refs} ->
        {value, state, more} = reference(module, :biome, state, active, source)
        {values ++ [value], state, refs ++ more}

      _value, _acc ->
        fail(:content_reference_kind_mismatch, "biomes require named biome references", source)
    end)
  end

  defp field(key, value, _state, _active, source)
       when key in [:model, :profile] or (key in @block_fields and not is_nil(value)),
       do:
         fail(
           :content_reference_kind_mismatch,
           "#{key} requires a named declaration reference",
           source
         )

  defp field(_key, value, state, active, source), do: materialize(value, state, active, source)

  defp expected_kind(key, _source) when key in @block_fields, do: :block
  defp expected_kind(:model, _source), do: :model
  defp expected_kind(:profile, _source), do: :profile
  defp expected_kind(:terrain, _source), do: :terrain

  defp expected_kind(key, source),
    do: fail(:content_reference_kind_mismatch, "unexpected reference in #{key}", source)

  defp reference(module, kind, state, active, source) do
    name = module_name(module)

    unless Map.has_key?(state.authored, name) or Map.has_key?(state.index, name),
      do: fail(:unresolved_content_reference, "unresolved #{kind} reference #{name}", source)

    {record, state} = lower(name, state, active)
    record = check_reference!(record, kind, state.plugin, source)
    value = if kind == :model, do: record.data.id, else: record.data
    {value, state, [Map.take(record, [:id, :module, :kind, :plugin_id])]}
  end

  defp check_reference!(record, kind, plugin, source) do
    unless record.plugin_id == plugin.id or record.plugin_id in plugin.dependencies,
      do:
        fail(
          :undeclared_content_dependency,
          "reference requires direct plugin dependency #{record.plugin_id}",
          source
        )

    unless record.kind == kind,
      do:
        fail(
          :content_reference_kind_mismatch,
          "expected #{kind}, got #{record.kind} for #{record.module}",
          source
        )

    record
  end

  defp build(%{builder: {module, function}} = declaration, _fields, plugin) do
    unless module in plugin.modules and Code.ensure_loaded?(module) and
             function_exported?(module, function, 1),
           do:
             fail(
               :invalid_content_builder,
               "model builder must be an owned module exporting #{function}/1",
               declaration.source
             )

    id = plugin.id <> ":" <> declaration.local_id
    data = apply(module, function, [id])

    unless match?(%Model{id: ^id}, data) and Model.validate(data) == :ok,
      do:
        fail(
          :invalid_content_configuration,
          "model builder returned invalid data or identity",
          declaration.source
        )

    data
  end

  defp build(declaration, fields, plugin) do
    if Map.has_key?(fields, :id),
      do: raise(ArgumentError, "identity belongs in the declaration options")

    id = plugin.id <> ":" <> declaration.local_id

    case declaration.kind do
      :profile ->
        validated_struct(Profile, fields)

      :terrain ->
        Terrain.new!(fields)

      :biome ->
        Biome.new!(Map.put(fields, :id, id))

      :worldgen ->
        Config.new!(fields)

      :model ->
        validated_struct(Model, Map.put(fields, :id, id))

      :character ->
        build_character(fields, id)
    end
  end

  defp build_character(fields, id) do
    if Enum.sort(Map.keys(fields)) != [:model, :profile],
      do:
        raise(
          ArgumentError,
          "characters require only :model and :profile; instance settings belong in game spawns"
        )

    data = struct!(Definition, Map.put(fields, :id, id))
    unless Definition.valid?(data), do: raise(ArgumentError, "invalid character definition")
    data
  end

  defp validated_struct(module, fields) do
    data = struct!(module, fields)

    unless module.validate(data) == :ok,
      do: raise(ArgumentError, "invalid #{inspect(module)} data")

    data
  end

  defp block_record(block) do
    %{
      kind: :block,
      plugin_id: block.plugin_id,
      local_id: block.local_id,
      id: block.plugin_id <> ":" <> block.local_id,
      module: module_name(block.module),
      data: Ref.new!(block.plugin_id, block.local_id)
    }
  end

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(module) when is_binary(module), do: module

  defp fail(code, message, source),
    do: throw({:content_error, Diagnostic.new!(code, message, source)})
end
