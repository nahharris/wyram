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
            flight_request: 0,
            sneaking: false,
            crawling: false,
            climbing: false,
            rolling: false,
            cancel_actions: false

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          epoch: non_neg_integer(),
          forward: number(),
          right: number(),
          yaw: number(),
          pitch: number(),
          running: boolean(),
          jump: boolean(),
          flight_request: non_neg_integer(),
          sneaking: boolean(),
          crawling: boolean(),
          climbing: boolean(),
          rolling: boolean(),
          cancel_actions: boolean()
        }
  @spec idle() :: t()
  def idle, do: %__MODULE__{}

  @doc "Release all controls while retaining look, epoch and acknowledgement sequence."
  @spec release(t()) :: t()
  def release(input),
    do: %{
      idle()
      | sequence: input.sequence,
        epoch: input.epoch,
        yaw: input.yaw,
        pitch: input.pitch,
        flight_request: input.flight_request,
        cancel_actions: true
    }

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

    if valid_sequence?(sequence) and valid_sequence?(epoch) and
         valid_sequence?(Map.get(packet, "flight_request", 0)) and Enum.all?(values, &bounded?/1) and
         valid_flags?(packet) do
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
         flight_request: Map.get(packet, "flight_request", 0),
         sneaking: Map.get(packet, "sneaking", false),
         crawling: Map.get(packet, "crawling", false),
         climbing: Map.get(packet, "climbing", false),
         rolling: Map.get(packet, "rolling", false),
         cancel_actions: Map.get(packet, "cancel_actions", false)
       }}
    else
      {:error, :invalid_input}
    end
  end

  def decode(_), do: {:error, :invalid_input}

  defp valid_sequence?(value),
    do: is_integer(value) and value >= 0 and value <= 9_000_000_000_000_000

  defp bounded?({value, min, max}), do: is_number(value) and value >= min and value <= max

  defp valid_flags?(packet),
    do:
      Enum.all?(
        ["sneaking", "crawling", "climbing", "rolling", "cancel_actions"],
        &is_boolean(Map.get(packet, &1, false))
      )
end
