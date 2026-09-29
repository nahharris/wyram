defmodule WyramMods.TestAddon do
  @moduledoc "Test-only content package loaded after a world already exists."
  @behaviour Wyram.Plugin

  @impl true
  def id, do: "test_addon"

  @impl true
  def blocks, do: [%{name: "prism", color: [33, 211, 177]}]

  @impl true
  def terrain, do: :none

  @impl true
  def interact(_block, _context), do: :pass
end
