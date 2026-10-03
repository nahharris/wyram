defmodule Wyram.Blocks do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block

  include Wyram.Blocks.Templates
  include Wyram.Blocks.Ground
  include Wyram.Blocks.Wooden
  include Wyram.Blocks.Liquids
end
