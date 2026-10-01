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

  @type block_definition :: %{required(:name) => String.t(), required(:color) => [integer()]}
  @type terrain_profile ::
          {:layered,
           %{
             required(:surface) => String.t(),
             required(:soil) => String.t(),
             required(:rock) => String.t()
           }}

  @callback player_profile() :: Wyram.Character.Profile.t()
  @callback character_models() :: [Wyram.Character.Model.t()]
  @callback characters() :: [Wyram.Character.Definition.t()]
  @optional_callbacks player_profile: 0, character_models: 0, characters: 0

  @callback blocks() :: [block_definition()]
  @callback terrain() :: terrain_profile() | :none
  @callback interact(String.t(), map()) ::
              :pass | {:set_block, {integer(), integer(), integer()}, String.t()}
end
