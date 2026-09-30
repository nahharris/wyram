defmodule Wyram.Character.Profile do
  @moduledoc "Reusable locomotion tuning and intent policy shared by characters and game plugins."

  defstruct walk_speed: 5.0,
            run_speed: 9.0,
            jump_speed: 7.0,
            gravity: 20.0,
            terminal_speed: 25.0,
            radius: 0.28,
            standing_height: 1.8,
            standing_eye: 1.62,
            crouch_height: 1.0,
            crouch_eye: 0.85,
            sneak_speed: 2.0

  @type t :: %__MODULE__{
          walk_speed: number(),
          run_speed: number(),
          jump_speed: number(),
          gravity: number(),
          terminal_speed: number(),
          radius: number(),
          standing_height: number(),
          standing_eye: number(),
          crouch_height: number(),
          crouch_eye: number(),
          sneak_speed: number()
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
      profile.sneak_speed
    ]

    if Enum.all?(values, &(is_number(&1) and &1 > 0 and &1 <= 100)) and
         profile.run_speed >= profile.walk_speed and valid_geometry?(profile) do
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

  defp valid_geometry?(p) do
    Enum.all?(
      [p.radius, p.standing_height, p.standing_eye, p.crouch_height, p.crouch_eye],
      &is_number/1
    ) and
      p.radius >= 0.1 and p.radius <= 2.0 and
      p.standing_height <= 8.0 and p.crouch_height >= 0.1 and
      p.crouch_height <= p.standing_height and
      valid_eyes?(p)
  end

  defp valid_eyes?(p),
    do:
      p.standing_eye > 0 and p.standing_eye < p.standing_height and p.crouch_eye > 0 and
        p.crouch_eye < p.crouch_height
end
