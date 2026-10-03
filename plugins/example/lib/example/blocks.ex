defmodule Example.Blocks do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block, plugin: Example
  alias Wyram.Capability.Material

  defblock Amber, id: "amber" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {232, 154, 44}}, override: true)
  end
end
