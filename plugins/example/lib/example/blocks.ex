defmodule Example.Blocks do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block
  alias Wyram.Capability.Material

  defblock Amber, id: "amber" do
    template Wyram.Blocks.Solid
    capability %Material{color: {232, 154, 44}}, override: true
  end
end
