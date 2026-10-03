defmodule Wyram.Plugin do
  @moduledoc "Public contracts and declaration entry point for installed game plugins."

  alias Wyram.Plugin.Catalog
  alias Wyram.Plugin.DSL.Entry

  @doc "Defines explicit plugin compiler metadata for an entry module."
  defmacro __using__(options) do
    caller = __CALLER__
    metadata = Entry.options!(options, caller)

    Module.register_attribute(caller.module, :wyram_collected_declarations, accumulate: true)
    Module.put_attribute(caller.module, :wyram_plugin_module, caller.module)
    Module.put_attribute(caller.module, :wyram_plugin_metadata, metadata)
    Module.register_attribute(caller.module, :wyram_catalogs, accumulate: true)
    Module.register_attribute(caller.module, :wyram_providers, accumulate: true)

    quote do
      @before_compile Wyram.Plugin.Declarations
      @before_compile Wyram.Plugin
      import Wyram.Plugin, only: [catalog: 1, provider: 1, game: 1]
      import Wyram.Plugin.Declarations, only: [defblock: 1, defblock: 2, defblock: 3]
    end
  end

  defmacro catalog(module_ast) do
    module = Entry.module!(module_ast, __CALLER__, "catalog module")
    source = Catalog.source(__CALLER__)

    Module.put_attribute(__CALLER__.module, :wyram_catalogs, %{
      module: module,
      source: source
    })

    quote do: :ok
  end

  defmacro provider(module_ast) do
    module = Entry.module!(module_ast, __CALLER__, "provider module")
    Module.put_attribute(__CALLER__.module, :wyram_providers, module)
    quote do: :ok
  end

  defmacro game(module_ast) do
    if Module.has_attribute?(__CALLER__.module, :wyram_game),
      do: Entry.error!(__CALLER__, "game may be declared only once")

    module = Entry.module!(module_ast, __CALLER__, "game module")
    Module.put_attribute(__CALLER__.module, :wyram_game, module)
    quote do: :ok
  end

  defmacro __before_compile__(env) do
    metadata = Module.get_attribute(env.module, :wyram_plugin_metadata)

    metadata = %{
      metadata
      | catalogs: env.module |> Module.get_attribute(:wyram_catalogs) |> Enum.reverse(),
        providers: env.module |> Module.get_attribute(:wyram_providers) |> Enum.reverse(),
        game: Module.get_attribute(env.module, :wyram_game)
    }

    quote do
      @doc false
      def __wyram_plugin__, do: unquote(Macro.escape(metadata))
    end
  end
end
