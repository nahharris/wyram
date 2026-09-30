defmodule Wyram.Character.ProfileTest do
  use ExUnit.Case, async: true

  alias Wyram.Character.Profile

  defmodule LegacyPlugin do
  end

  defmodule CustomPlugin do
    alias Wyram.Character.Profile

    def player_profile,
      do: Map.merge(Profile.default(), %{walk_speed: 2.0, run_speed: 4.0})
  end

  defmodule InvalidPlugin do
    def player_profile, do: %{walk_speed: -1}
  end

  test "optional plugin profiles preserve legacy plugins and validate custom tuning" do
    assert Profile.from_plugin(LegacyPlugin) == {:ok, Profile.default()}
    assert {:ok, custom} = Profile.from_plugin(CustomPlugin)
    assert Profile.motion(custom, true).speed == 4.0
    assert Profile.from_plugin(InvalidPlugin) == {:error, :invalid_character_profile}
  end

  test "default profile preserves existing movement tuning" do
    profile = Profile.default()
    assert profile.walk_speed == 5.0
    assert profile.run_speed == 9.0
    assert profile.jump_speed == 7.0
    assert profile.gravity == 20.0
    assert profile.terminal_speed == 25.0
    assert Profile.validate(profile) == :ok
  end

  test "each character resolves walking and running from its own profile" do
    profile = Map.merge(Profile.default(), %{walk_speed: 2.0, run_speed: 4.0})

    assert Profile.motion(profile, false) == %{
             mode: :walk,
             speed: 2.0,
             jump_speed: 7.0,
             gravity: 20.0,
             terminal_speed: 25.0
           }

    assert Profile.motion(profile, true).speed == 4.0
    assert Profile.motion(profile, true).mode == :run
  end

  test "malformed and unsafe profiles are rejected at the public boundary" do
    assert Profile.validate(%{}) == {:error, :invalid_character_profile}

    for field <- [:walk_speed, :run_speed, :jump_speed, :gravity, :terminal_speed],
        value <- [0, -1, nil, "fast", 101] do
      assert Profile.validate(Map.put(Profile.default(), field, value)) ==
               {:error, :invalid_character_profile}
    end

    assert Profile.validate(%{Profile.default() | walk_speed: 10.0, run_speed: 5.0}) ==
             {:error, :invalid_character_profile}
  end
end
