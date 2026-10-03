defmodule Wyram.Plugin.ContentDSL do
  @moduledoc false
  alias Wyram.Plugin.{Catalog, ContentRef, Kind}
  alias Wyram.Plugin.DSL.{Entry, Literal, StructLiteral}

  for kind <- [:biome, :shaping, :profile, :model, :character, :worldgen] do
    name = String.to_atom("def#{kind}")

    defmacro unquote(name)(symbol),
      do: define(unquote(kind), symbol, [], nil, __CALLER__)

    defmacro unquote(name)(symbol, do: body),
      do: define(unquote(kind), symbol, [], body, __CALLER__)

    defmacro unquote(name)(symbol, options),
      do: define(unquote(kind), symbol, options, nil, __CALLER__)

    defmacro unquote(name)(symbol, options, do: body),
      do: define(unquote(kind), symbol, options, body, __CALLER__)
  end

  defp define(kind, {:__aliases__, _, [symbol]}, options, body, env) when is_atom(symbol) do
    unless Module.get_attribute(env.module, :wyram_catalog_kind) == kind,
      do: Entry.error!(env, "declaration does not match catalog kind")

    options = Entry.keyword_options!(options, env, "def#{kind}")

    if Keyword.keys(options) -- [:id, :build] != [],
      do: Entry.error!(env, "unknown def#{kind} option")

    id = Entry.local_id!(symbol, options, env)

    plugin = Module.get_attribute(env.module, :wyram_plugin_module)
    module = Module.concat(plugin, Kind.namespace(kind) <> ".#{symbol}")
    ensure_available!(module, plugin, kind, env)
    {data, builder} = configuration!(kind, options, body, env)

    declaration = %{
      plugin: plugin,
      module: module,
      kind: kind,
      local_id: id,
      source: Catalog.source(env),
      data: data,
      builder: builder
    }

    Module.put_attribute(env.module, :wyram_content_declarations, declaration)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        def __wyram_content__,
          do: unquote(Macro.escape(Map.take(declaration, [:plugin, :module, :kind, :local_id])))

        def ref do
          %ContentRef{
            plugin_id: unquote(plugin).__wyram_plugin__().id,
            local_id: unquote(id),
            kind: unquote(kind)
          }
        end
      end
    end
  end

  defp define(kind, _symbol, _options, _body, env),
    do: Entry.error!(env, "def#{kind} name must be one unqualified module symbol")

  defp configuration!(kind, options, body, env) do
    case {Keyword.get(options, :build), body} do
      {nil, nil} ->
        {%{}, nil}

      {nil, body} ->
        value = Literal.normalize!(body, env, "content configuration")

        unless is_map(value) and not match?(%StructLiteral{}, value),
          do: Entry.error!(env, "content bodies require a literal map of fields")

        {value, nil}

      {{module_ast, function}, nil} when kind == :model and is_atom(function) ->
        {%{}, {Entry.module!(module_ast, env, "model builder"), function}}

      _ ->
        Entry.error!(env, "only models support build: {Module, :function}, without a data body")
    end
  end

  defp ensure_available!(module, plugin, kind, env) do
    if Code.ensure_loaded?(module) do
      matches =
        function_exported?(module, :__wyram_content__, 0) and
          match?(%{plugin: ^plugin, kind: ^kind}, module.__wyram_content__())

      unless matches,
        do: Entry.error!(env, "generated content module #{inspect(module)} is already defined")
    end
  end
end
