defmodule Wyram.WorldGen do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :worldgen

  defworldgen Wilderness do
    %{biomes: [Wyram.Biomes.Wilderness]}
  end
end
