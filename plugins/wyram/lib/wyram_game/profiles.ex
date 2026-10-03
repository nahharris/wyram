defmodule WyramGame.Profiles do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :profile
  alias Wyram.Units

  defprofile Player, id: "player" do
    %{
      fly_enabled: true,
      radius: Units.pixels(3),
      standing_height: Units.blocks(1, 3),
      standing_eye: Units.blocks(1, 1),
      crouch_height: Units.pixels(10),
      crouch_eye: Units.pixels(7),
      prone_height: Units.pixels(7),
      prone_eye: Units.pixels(4)
    }
  end

  defprofile Companion, id: "companion" do
    %{
      walk_speed: 3.2,
      run_speed: 6.5,
      climb_height: 2,
      wall_slide_enabled: false,
      roll_distance: 2.0,
      radius: Units.pixels(3),
      standing_height: Units.blocks(1, 3),
      standing_eye: Units.blocks(1, 1),
      crouch_height: Units.pixels(10),
      crouch_eye: Units.pixels(7),
      prone_height: Units.pixels(7),
      prone_eye: Units.pixels(4)
    }
  end
end
