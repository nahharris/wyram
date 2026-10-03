defmodule Wyram.Plugin.Declarations do
  @moduledoc false

  alias Wyram.Block.Ref
  alias Wyram.Plugin.{Declaration, SourceLocation}
  alias Wyram.Plugin.DSL.{Capability, CollectedDeclaration, Entry, Literal, StructLiteral}

  defmacro defblock(name, options), do: define_block(name, options, nil, __CALLER__)
  defmacro defblock(name, options, do: body), do: define_block(name, options, body, __CALLER__)

  defmacro __before_compile__(env) do
    declarations =
      env.module |> Module.get_attribute(:wyram_collected_declarations) |> Enum.reverse()

    quote do
      def __wyram_declarations__, do: unquote(Macro.escape(declarations))
    end
  end

  defp define_block(name_ast, options_ast, body, env) do
    unless Module.get_attribute(env.module, :wyram_catalog_kind) in [nil, :block],
      do: Entry.error!(env, "defblock requires a block catalog")

    {template?, local_id} = block_role!(options_ast, env)

    symbol = symbol!(name_ast, env)
    plugin = Module.get_attribute(env.module, :wyram_plugin_module)
    module = Module.concat(plugin, "Blocks.#{symbol}")
    source = source!(env, name_ast)
    entries = entries!(body, env)

    declaration = %CollectedDeclaration{
      plugin: plugin,
      plugin_id: nil,
      local_id: local_id,
      module: module,
      kind: :block,
      role: if(template?, do: :template, else: :registered),
      source: source,
      entries: entries
    }

    ensure_generated_names_available!([declaration], env)
    Module.put_attribute(env.module, :wyram_collected_declarations, declaration)

    quote do
      unquote(generated_module_ast(declaration))
      :ok
    end
  end

  defp symbol!({:__aliases__, _meta, [symbol]}, _env) when is_atom(symbol), do: symbol

  defp symbol!(_ast, env),
    do: Entry.error!(env, "defblock name must be one unqualified module symbol")

  defp entries!(nil, _env), do: []

  defp entries!({:__block__, _meta, expressions}, env) do
    Enum.map(expressions, &entry!(&1, env))
  end

  defp entries!(expression, env), do: [entry!(expression, env)]

  defp entry!({:template, meta, [module_ast]}, env) do
    module = Entry.module!(module_ast, line_env(env, meta), "template reference")
    Declaration.Template.new!(module, source!(line_env(env, meta), module_ast))
  end

  defp entry!({:capability, meta, args}, env) when is_list(args) do
    capability!(args, line_env(env, meta))
  end

  defp entry!(_expression, env),
    do: Entry.error!(env, "block bodies may contain only template and capability entries")

  defp capability!([config_ast], env), do: capability!(config_ast, [], env)

  defp capability!([config_ast, options_ast], env) do
    options = Entry.keyword_options!(options_ast, env, "capability")
    unknown = Keyword.keys(options) -- [:override]
    if unknown != [], do: Entry.error!(env, "unknown capability option(s): #{inspect(unknown)}")
    capability!(config_ast, options, env)
  end

  defp capability!(_args, env),
    do: Entry.error!(env, "capability expects a named configuration struct and optional options")

  defp capability!(config_ast, options, env) do
    override = Keyword.get(options, :override, false)
    unless is_boolean(override), do: Entry.error!(env, "override must be a boolean literal")

    config = Literal.normalize!(config_ast, env)

    unless match?(%StructLiteral{}, config) do
      Entry.error!(env, "capability configuration must be a named struct literal")
    end

    %Capability{
      config_module: config.module,
      config: config,
      override: override,
      source: source!(env, config_ast)
    }
  end

  defp source!(env, ast) do
    metadata =
      case ast do
        {_, metadata, _} when is_list(metadata) -> metadata
        _ -> []
      end

    %SourceLocation{
      file: env.file,
      line: Keyword.get(metadata, :line, env.line),
      column: Keyword.get(metadata, :column),
      module: env.module
    }
  end

  defp line_env(env, metadata), do: %{env | line: Keyword.get(metadata, :line, env.line)}

  defp generated_module_ast(%CollectedDeclaration{} = declaration) do
    module = declaration.module
    plugin = declaration.plugin
    local_id = declaration.local_id

    quote do
      defmodule unquote(module) do
        @moduledoc false

        def __wyram_generated_declaration__ do
          unquote(
            Macro.escape(%{
              plugin: plugin,
              declaration_module: module,
              local_id: local_id,
              kind: declaration.kind,
              role: declaration.role,
              source: declaration.source
            })
          )
        end

        if unquote(declaration.role) == :registered do
          def ref do
            plugin_metadata = unquote(plugin).__wyram_plugin__()
            Ref.new!(plugin_metadata.id, unquote(local_id))
          end
        end
      end
    end
  end

  defp ensure_generated_names_available!(declarations, env) do
    Enum.each(declarations, fn declaration ->
      unless generated_name_available?(declaration) do
        Entry.error!(
          env,
          "generated declaration module #{inspect(declaration.module)} is already defined with a different marker"
        )
      end
    end)
  end

  defp block_role!(options_ast, env) do
    options = Entry.keyword_options!(options_ast, env, "defblock")
    reject_unknown_block_options!(options, env)
    template? = Keyword.get(options, :template, false)
    local_id = Keyword.get(options, :id)

    unless is_boolean(template?), do: Entry.error!(env, "template must be a boolean literal")
    validate_block_identity!(template?, local_id, env)

    {template?, local_id}
  end

  defp reject_unknown_block_options!(options, env) do
    case Keyword.keys(options) -- [:id, :template] do
      [] -> :ok
      unknown -> Entry.error!(env, "unknown defblock option(s): #{inspect(unknown)}")
    end
  end

  defp validate_block_identity!(true, nil, _env), do: :ok

  defp validate_block_identity!(true, _local_id, env),
    do: Entry.error!(env, "template declarations cannot have an id")

  defp validate_block_identity!(false, local_id, env) when is_binary(local_id) do
    unless Ref.valid_local_id?(local_id), do: Entry.error!(env, "block id is invalid")
  end

  defp validate_block_identity!(false, _local_id, env),
    do: Entry.error!(env, "registered blocks require a literal id string")

  defp generated_name_available?(declaration) do
    case :code.is_loaded(declaration.module) do
      false -> true
      _loaded -> generated_marker_matches?(declaration)
    end
  end

  defp generated_marker_matches?(declaration) do
    module = declaration.module

    if function_exported?(module, :__wyram_generated_declaration__, 0) do
      module.__wyram_generated_declaration__()
      |> same_generated_owner?(declaration)
    else
      false
    end
  rescue
    _ -> false
  end

  defp same_generated_owner?(marker, declaration) when is_map(marker) do
    Map.keys(marker) |> Enum.sort() == [
      :declaration_module,
      :kind,
      :local_id,
      :plugin,
      :role,
      :source
    ] and
      marker.plugin == declaration.plugin and
      marker.declaration_module == declaration.module and
      valid_generated_identity?(marker) and
      SourceLocation.valid?(marker.source)
  end

  defp same_generated_owner?(_marker, _declaration), do: false

  defp valid_generated_identity?(%{kind: :block, role: :registered, local_id: local_id}),
    do: Ref.valid_local_id?(local_id)

  defp valid_generated_identity?(%{kind: :block, role: :template, local_id: nil}), do: true
  defp valid_generated_identity?(_marker), do: false
end
