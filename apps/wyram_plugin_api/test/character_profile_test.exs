defmodule Wyram.Character.ProfileTest do
  use ExUnit.Case, async: true

  alias Wyram.Character.{Input, Posture, Profile, State}

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

  test "body geometry and sneak tuning are safe and reusable per character" do
    for {key, value} <- [
          radius: 0.09,
          radius: 2.1,
          standing_height: 9,
          crouch_height: 0,
          crouch_height: 3,
          crouch_eye: 1.0,
          standing_eye: 1.8,
          sneak_speed: 0,
          prone_height: 0.09,
          prone_height: 1.1,
          prone_eye: 0.6,
          crawl_speed: 0,
          climb_height: -1,
          climb_height: 4,
          climb_height: 1.5,
          climb_speed: 0,
          slide_enabled: "yes",
          slide_entry_speed: 0,
          slide_friction: 0,
          slide_duration: 0,
          wall_slide_enabled: "yes",
          wall_slide_speed: 0
        ] do
      assert Profile.validate(Map.put(Profile.default(), key, value)) ==
               {:error, :invalid_character_profile}
    end

    profile = %{Profile.default() | crouch_height: 0.8, crouch_eye: 0.65, sneak_speed: 1.3}
    assert :ok = Profile.validate(profile)
    body = State.new(profile, {0, 0, 0})

    {wanted, _} =
      Posture.request(body, %{Input.idle() | sneaking: true})

    assert wanted.height == 0.8
    assert wanted.eye_height == 0.65
  end
end
