defmodule Example do
  @moduledoc "An independently packaged content plugin."
  use Wyram.Plugin
  catalog(:blocks, Example.Blocks)
end
