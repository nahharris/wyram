defmodule Wyram.Plugin.Declarations do
  @moduledoc "Collects block declarations for one plugin entry module."

  alias Wyram.Plugin.DSL.{Capability, CollectedDeclaration, Entry, Literal, StructLiteral}
  alias Wyram.Plugin.{Declaration, SourceLocation}

  defmacro __using__(options) do
    options = Entry.keyword_options!(options, __CALLER__, "declarations")
    unknown = Keyword.keys(options) -- [:plugin]

    if unknown != [],
      do: Entry.error!(__CALLER__, "unknown declarations option(s): #{inspect(unknown)}")

    plugin = Entry.module!(Keyword.get(options, :plugin), __CALLER__, "plugin")
    Module.register_attribute(__CALLER__.module, :wyram_collected_declarations, accumulate: true)
    Module.put_attribute(__CALLER__.module, :wyram_plugin_module, plugin)

    quote do
      @before_compile Wyram.Plugin.Declarations
      import Wyram.Plugin.Declarations, only: [defblock: 2, defblock: 3]
    end
  end

  defmacro defblock(name, options), do: define_block(name, options, nil, __CALLER__)
  defmacro defblock(name, options, do: body), do: define_block(name, options, body, __CALLER__)

  defmacro __before_compile__(env) do
    declarations =
      env.module |> Module.get_attribute(:wyram_collected_declarations) |> Enum.reverse()

    ensure_generated_names_available!(declarations, env)

    generated_modules = Enum.map(declarations, &generated_module_ast/1)

    quote do
      def __wyram_declarations__, do: unquote(Macro.escape(declarations))
      unquote_splicing(generated_modules)
    end
  end

  defp define_block(name_ast, options_ast, body, env) do
    options = Entry.keyword_options!(options_ast, env, "defblock")
    unknown = Keyword.keys(options) -- [:id, :template]
    if unknown != [], do: Entry.error!(env, "unknown defblock option(s): #{inspect(unknown)}")

    template? = Keyword.get(options, :template, false)

    unless is_boolean(template?), do: Entry.error!(env, "template must be a boolean literal")

    local_id = Keyword.get(options, :id)

    cond do
      template? and not is_nil(local_id) ->
        Entry.error!(env, "template declarations cannot have an id")

      template? ->
        :ok

      not is_binary(local_id) ->
        Entry.error!(env, "registered blocks require a literal id string")

      not Wyram.Block.Ref.valid_local_id?(local_id) ->
        Entry.error!(env, "block id is invalid")

      true ->
        :ok
    end

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

    Module.put_attribute(env.module, :wyram_collected_declarations, declaration)
    quote(do: :ok)
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
            plugin_metadata = apply(unquote(plugin), :__wyram_plugin__, [])
            Wyram.Block.Ref.new!(plugin_metadata.id, unquote(local_id))
          end
        end
      end
    end
  end

  defp ensure_generated_names_available!(declarations, env) do
    Enum.each(declarations, fn declaration ->
      case :code.is_loaded(declaration.module) do
        false ->
          :ok

        _ ->
          Entry.error!(
            env,
            "generated declaration module #{inspect(declaration.module)} is already defined"
          )
      end
    end)
  end
end
