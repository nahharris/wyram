defmodule Wyram.Character.Definition do
  @moduledoc "Reusable spawn/profile/model binding, independent of character ownership."
  alias Wyram.Character.Profile

  defstruct id: "player",
            model: "default",
            profile: nil,
            position: {0.5, 71.38, 0.5},
            yaw: 0.0,
            pitch: -0.15

  @type t :: %__MODULE__{
          id: String.t(),
          model: String.t(),
          profile: Profile.t(),
          position: {number(), number(), number()},
          yaw: number(),
          pitch: number()
        }
  def player(profile, model \\ "default"), do: %__MODULE__{profile: profile, model: model}

  def valid?(%__MODULE__{} = d) do
    label?(d.id) and label?(d.model) and Profile.validate(d.profile) == :ok and
      position?(d.position) and
      is_number(d.yaw) and abs(d.yaw) <= 1000 and is_number(d.pitch) and abs(d.pitch) <= 1.55
  end

  def valid?(_), do: false
  defp label?(v), do: is_binary(v) and byte_size(v) in 1..64 and String.valid?(v)
  defp position?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 1_000_000))
  defp position?(_), do: false
end
