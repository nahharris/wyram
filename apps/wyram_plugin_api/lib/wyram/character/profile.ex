defmodule Wyram.Character.Profile do
  @moduledoc "Reusable locomotion tuning and intent policy shared by characters and game plugins."

  defstruct walk_speed: 5.0, run_speed: 9.0, jump_speed: 7.0, gravity: 20.0, terminal_speed: 25.0

  @type t :: %__MODULE__{
          walk_speed: number(),
          run_speed: number(),
          jump_speed: number(),
          gravity: number(),
          terminal_speed: number()
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
      profile.terminal_speed
    ]

    if Enum.all?(values, &(is_number(&1) and &1 > 0 and &1 <= 100)) and
         profile.run_speed >= profile.walk_speed do
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
end
