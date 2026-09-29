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

  @callback blocks() :: [block_definition()]
  @callback terrain() :: terrain_profile() | :none
  @callback interact(String.t(), map()) ::
              :pass | {:set_block, {integer(), integer(), integer()}, String.t()}
end
