defmodule Wyram.Capability.Collision do
  @moduledoc "Collision geometry; :none leaves the block visible and selectable."
  @type t :: %__MODULE__{shape: Wyram.Shape.Cube.t() | :none}
  defstruct [:shape]
end
