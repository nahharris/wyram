defmodule Wyram.Blocks.Wooden do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block
  alias Wyram.Capability.Material

  defblock Wood do
    template Wyram.Blocks.Solid
    capability %Material{color: {135, 94, 54}}, override: true
  end

  defblock Leaves do
    template Wyram.Blocks.Solid
    capability %Material{color: {65, 116, 67}}, override: true
  end
end
