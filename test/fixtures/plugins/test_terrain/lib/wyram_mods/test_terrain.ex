defmodule WyramMods.TestTerrain do
  @moduledoc "Test-only terrain with names unrelated to the official game."
  @behaviour Wyram.Plugin

  @impl true
  def id, do: "test_terrain"

  @impl true
  def blocks do
    [
      %{name: "violet", color: [73, 39, 177]},
      %{name: "ochre", color: [201, 113, 37]},
      %{name: "slate", color: [42, 63, 84]}
    ]
  end

  @impl true
  def terrain do
    {:layered,
     %{surface: "test_terrain:violet", soil: "test_terrain:ochre", rock: "test_terrain:slate"}}
  end

  @impl true
  def interact(_block, _context), do: :pass
end
