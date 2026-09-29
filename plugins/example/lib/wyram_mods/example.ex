defmodule WyramMods.Example do
  @moduledoc "An independently packaged content plugin."
  @behaviour Wyram.Plugin

  @impl true
  def blocks, do: [%{name: "amber", color: [232, 154, 44]}]

  @impl true
  def terrain, do: :none

  @impl true
  def interact("example:amber", %{position: {x, y, z}}) do
    {:set_block, {x, y + 1, z}, "example:amber"}
  end

  def interact(_, _), do: :pass
end
