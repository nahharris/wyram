defmodule Wyram.Capability.Liquid do
  @moduledoc "Source-driven liquid flow. Requires explicitly noncolliding cube geometry."
  @type t :: %__MODULE__{flow_ms: pos_integer(), max_level: 1..7}
  defstruct flow_ms: 200, max_level: 7
end
