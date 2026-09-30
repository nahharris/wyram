defmodule Wyram.Character.Input do
  @moduledoc "Validated, sequenced character intent. Client positions and speeds are never inputs."
  defstruct sequence: 0,
            epoch: 0,
            forward: 0.0,
            right: 0.0,
            yaw: 0.0,
            pitch: 0.0,
            running: false,
            jump: false,
            sneaking: false,
            crawling: false

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          epoch: non_neg_integer(),
          forward: number(),
          right: number(),
          yaw: number(),
          pitch: number(),
          running: boolean(),
          jump: boolean(),
          sneaking: boolean(),
          crawling: boolean()
        }
  @spec idle() :: t()
  def idle, do: %__MODULE__{}

  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_input}
  def decode(
        %{
          "sequence" => sequence,
          "epoch" => epoch,
          "forward" => forward,
          "right" => right,
          "yaw" => yaw,
          "pitch" => pitch,
          "running" => running,
          "jump" => jump
        } = packet
      )
      when is_boolean(running) and is_boolean(jump) do
    values = [{forward, -1, 1}, {right, -1, 1}, {yaw, -1000, 1000}, {pitch, -1.55, 1.55}]

    if valid_sequence?(sequence) and valid_sequence?(epoch) and Enum.all?(values, &bounded?/1) and
         is_boolean(Map.get(packet, "sneaking", false)) and
         is_boolean(Map.get(packet, "crawling", false)) do
      {:ok,
       %__MODULE__{
         sequence: sequence,
         epoch: epoch,
         forward: forward,
         right: right,
         yaw: yaw,
         pitch: pitch,
         running: running,
         jump: jump,
         sneaking: Map.get(packet, "sneaking", false),
         crawling: Map.get(packet, "crawling", false)
       }}
    else
      {:error, :invalid_input}
    end
  end

  def decode(_), do: {:error, :invalid_input}

  defp valid_sequence?(value),
    do: is_integer(value) and value >= 0 and value <= 9_000_000_000_000_000

  defp bounded?({value, min, max}), do: is_number(value) and value >= min and value <= max
end
