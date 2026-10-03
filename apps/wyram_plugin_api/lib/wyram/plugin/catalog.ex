defmodule Wyram.Plugin.Catalog do
  @moduledoc "Explicit, composable catalogs of one content kind, owned by a plugin."
  alias Wyram.Plugin.DSL.Entry
  alias Wyram.Plugin.{Kind, SourceLocation}

  defmacro __using__(options) do
    env = __CALLER__
    options = Entry.keyword_options!(options, env, "catalog")

    if Keyword.keys(options) != [:kind],
      do: Entry.error!(env, "unknown catalog option")

    plugin = Entry.plugin!(env)
    kind = Kind.validate!(Keyword.get(options, :kind), env)
    Module.put_attribute(env.module, :wyram_plugin_module, plugin)
    Module.put_attribute(env.module, :wyram_catalog_kind, kind)
    Module.register_attribute(env.module, :wyram_includes, accumulate: true)
    Module.register_attribute(env.module, :wyram_collected_declarations, accumulate: true)
    Module.register_attribute(env.module, :wyram_content_declarations, accumulate: true)

    imports =
      case kind do
        :block ->
          quote do
            import Wyram.Plugin.Declarations, only: [defblock: 1, defblock: 2, defblock: 3]
          end

        kind ->
          name = String.to_atom("def#{kind}")

          quote do
            import Wyram.Plugin.ContentDSL,
              only: [{unquote(name), 1}, {unquote(name), 2}, {unquote(name), 3}]
          end
      end

    quote do
      import Wyram.Plugin.Catalog, only: [include: 1]
      unquote(imports)
      @before_compile Wyram.Plugin.Declarations
      @before_compile Wyram.Plugin.Catalog
    end
  end

  defmacro include(module_ast) do
    env = __CALLER__
    module = Entry.module!(module_ast, env, "included catalog")
    Module.put_attribute(env.module, :wyram_includes, %{module: module, source: source(env)})
    quote do: :ok
  end

  defmacro __before_compile__(env) do
    metadata = %{
      plugin: Module.get_attribute(env.module, :wyram_plugin_module),
      kind: Module.get_attribute(env.module, :wyram_catalog_kind),
      includes: env.module |> Module.get_attribute(:wyram_includes) |> Enum.reverse(),
      declarations:
        env.module |> Module.get_attribute(:wyram_content_declarations) |> Enum.reverse()
    }

    quote do
      @doc false
      def __wyram_catalog__, do: unquote(Macro.escape(metadata))
    end
  end

  @doc false
  def source(env), do: %SourceLocation{file: env.file, line: env.line, module: env.module}
end
