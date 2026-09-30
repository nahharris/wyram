defmodule Wyram.Plugin do
  @moduledoc "Public contract implemented by installed game plugins."

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
