defmodule Wyram.Capability.Material do
  @moduledoc "Visual material configuration for a block."
  @type t :: %__MODULE__{
          color: {0..255, 0..255, 0..255},
          mode: :opaque | :blended | :emissive,
          opacity: 1..255
        }
  defstruct [:color, mode: :opaque, opacity: 255]
end
