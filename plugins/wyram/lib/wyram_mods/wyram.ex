defmodule WyramMods.Wyram do
  @moduledoc "The default creative voxel game, implemented through the public plugin contract."
  @behaviour Wyram.Plugin

  @impl true
  def player_profile, do: Wyram.Character.Profile.default()

  @impl true
  def character_models, do: WyramMods.Characters.models()

  @impl true
  def characters, do: WyramMods.Characters.definitions()

  @impl true
  def blocks do
    [
      %{name: "grass", color: [96, 150, 76]},
      %{name: "dirt", color: [118, 82, 54]},
      %{name: "stone", color: [126, 128, 134]},
      %{name: "wood", color: [135, 94, 54]}
    ]
  end

  @impl true
  def terrain do
    {:layered, %{surface: "wyram:grass", soil: "wyram:dirt", rock: "wyram:stone"}}
  end

  @impl true
  def interact(_block, _context), do: :pass
end
