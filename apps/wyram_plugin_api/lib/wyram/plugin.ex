defmodule Wyram.Plugin do
  @moduledoc "Public contracts and declaration entry point for installed game plugins."

  alias Wyram.Plugin.DSL.Entry

  @doc "Defines explicit plugin compiler metadata for an entry module."
  defmacro __using__(options) do
    caller = __CALLER__
    metadata = Entry.options!(options, caller)

    Module.register_attribute(caller.module, :wyram_collected_declarations, accumulate: true)
    Module.put_attribute(caller.module, :wyram_plugin_module, caller.module)

    quote do
      @before_compile Wyram.Plugin.Declarations
      import Wyram.Plugin.Declarations, only: [defblock: 2, defblock: 3]

      @doc false
      def __wyram_plugin__, do: unquote(Macro.escape(metadata))
    end
  end
end
