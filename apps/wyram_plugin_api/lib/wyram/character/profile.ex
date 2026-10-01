defmodule Wyram.Character.Profile do
  @moduledoc "Reusable locomotion tuning and intent policy shared by characters and game plugins."

  defstruct walk_speed: 5.0,
            run_speed: 9.0,
            jump_speed: 9.4,
            gravity: 36.0,
            terminal_speed: 25.0,
            ground_acceleration: 40.0,
            ground_deceleration: 55.0,
            air_acceleration: 12.0,
            jump_delay: 0.04,
            landing_duration: 0.08,
            radius: 0.28,
            standing_height: 1.8,
            standing_eye: 1.62,
            crouch_height: 1.0,
            crouch_eye: 0.85,
            sneak_speed: 2.0,
            prone_height: 0.6,
            prone_eye: 0.45,
            crawl_speed: 0.65,
            climb_height: 3,
            climb_speed: 6.0,
            slide_enabled: true,
            slide_entry_speed: 6.0,
            slide_friction: 10.0,
            slide_duration: 0.6,
            wall_slide_enabled: true,
            wall_slide_speed: 2.0,
            roll_enabled: true,
            roll_distance: 3.0,
            roll_duration: 0.35,
            roll_cooldown: 0.8

  @type t :: %__MODULE__{
          walk_speed: number(),
          run_speed: number(),
          jump_speed: number(),
          gravity: number(),
          terminal_speed: number(),
          ground_acceleration: number(),
          ground_deceleration: number(),
          air_acceleration: number(),
          jump_delay: number(),
          landing_duration: number(),
          radius: number(),
          standing_height: number(),
          standing_eye: number(),
          crouch_height: number(),
          crouch_eye: number(),
          sneak_speed: number(),
          prone_height: number(),
          prone_eye: number(),
          crawl_speed: number(),
          climb_height: non_neg_integer(),
          climb_speed: number(),
          slide_enabled: boolean(),
          slide_entry_speed: number(),
          slide_friction: number(),
          slide_duration: number(),
          wall_slide_enabled: boolean(),
          wall_slide_speed: number(),
          roll_enabled: boolean(),
          roll_distance: number(),
          roll_duration: number(),
          roll_cooldown: number()
        }
  @type motion :: %{
          mode: :walk | :run,
          speed: number(),
          jump_speed: number(),
          gravity: number(),
          terminal_speed: number()
        }
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec validate(term()) :: :ok | {:error, :invalid_character_profile}
  def validate(%__MODULE__{} = profile) do
    values = [
      profile.walk_speed,
      profile.run_speed,
      profile.jump_speed,
      profile.gravity,
      profile.terminal_speed,
      profile.ground_acceleration,
      profile.ground_deceleration,
      profile.air_acceleration,
      profile.jump_delay,
      profile.landing_duration,
      profile.sneak_speed,
      profile.crawl_speed,
      profile.climb_speed,
      profile.slide_entry_speed,
      profile.slide_friction,
      profile.slide_duration,
      profile.wall_slide_speed,
      profile.roll_distance,
      profile.roll_duration,
      profile.roll_cooldown
    ]

    if Enum.all?(values, &(is_number(&1) and &1 > 0 and &1 <= 100)) and
         valid_motion?(profile) and valid_geometry?(profile) and
         valid_capabilities?(profile) do
      :ok
    else
      {:error, :invalid_character_profile}
    end
  end

  def validate(_), do: {:error, :invalid_character_profile}

  @doc "Load the optional game profile; legacy plugins retain the default tuning."
  @spec from_plugin(module()) :: {:ok, t()} | {:error, :invalid_character_profile}
  def from_plugin(module) do
    profile =
      if function_exported?(module, :player_profile, 0),
        do: module.player_profile(),
        else: default()

    with :ok <- validate(profile), do: {:ok, profile}
  end

  @doc "Resolve intent in Elixir; consumers receive approved tuning rather than choosing speeds."
  @spec motion(t(), boolean()) :: motion()
  def motion(%__MODULE__{} = profile, running) when is_boolean(running) do
    %{
      mode: if(running, do: :run, else: :walk),
      speed: if(running, do: profile.run_speed, else: profile.walk_speed),
      jump_speed: profile.jump_speed,
      gravity: profile.gravity,
      terminal_speed: profile.terminal_speed
    }
  end

  defp valid_motion?(p),
    do:
      p.run_speed >= p.walk_speed and p.sneak_speed <= p.walk_speed and
        p.crawl_speed < p.sneak_speed and p.jump_delay <= 0.15 and p.landing_duration <= 0.25

  defp valid_geometry?(p) do
    Enum.all?(
      [
        p.radius,
        p.standing_height,
        p.standing_eye,
        p.crouch_height,
        p.crouch_eye,
        p.prone_height,
        p.prone_eye
      ],
      &is_number/1
    ) and
      p.radius >= 0.1 and p.radius <= 2.0 and
      p.standing_height <= 8.0 and p.crouch_height >= 0.1 and
      valid_heights?(p) and
      valid_eyes?(p)
  end

  defp valid_eyes?(p),
    do:
      p.standing_eye > 0 and p.standing_eye < p.standing_height and p.crouch_eye > 0 and
        p.crouch_eye < p.crouch_height and p.prone_eye > 0 and p.prone_eye < p.prone_height

  defp valid_heights?(p),
    do:
      p.crouch_height <= p.standing_height and p.prone_height >= 0.1 and
        p.prone_height <= p.crouch_height

  defp valid_climb?(p), do: is_integer(p.climb_height) and p.climb_height in 0..3

  defp valid_roll?(p),
    do:
      is_boolean(p.roll_enabled) and p.roll_duration >= 0.1 and p.roll_duration <= 3 and
        p.roll_distance <= 8 and p.roll_cooldown >= p.roll_duration and
        p.roll_distance / p.roll_duration <= 100

  defp valid_capabilities?(p),
    do:
      Enum.all?([p.slide_enabled, p.wall_slide_enabled, p.roll_enabled], &is_boolean/1) and
        valid_climb?(p) and valid_roll?(p)
end
