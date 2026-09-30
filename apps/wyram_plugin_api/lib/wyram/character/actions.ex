defmodule Wyram.Character.Actions do
  @moduledoc "Shared action dispatch keeps character ownership independent of each traversal policy."
  alias Wyram.Character.{Climb, Input, Roll, Slide, WallSlide}

  def begin(entries) do
    entries =
      Enum.map(entries, fn {id, body, input} ->
        if input.cancel_actions,
          do: {id, %{body | action: nil}, Input.release(input)},
          else: {id, body, input}
      end)

    Roll.choose(entries)
  end

  def choose(entries, collision) do
    with {:ok, entries} <- WallSlide.choose(entries, collision) do
      entries |> Slide.choose() |> Climb.choose(collision)
    end
  end

  def prepare(%{action: %{kind: :roll}} = body, input), do: Roll.prepare(body, input)
  def prepare(%{action: %{kind: :wall_slide}} = body, input), do: WallSlide.prepare(body, input)
  def prepare(%{action: %{kind: :slide}} = body, input), do: Slide.prepare(body, input)
  def prepare(body, input), do: Climb.prepare(body, input)
  def finish(%{action: %{kind: :roll}} = body, result), do: Roll.finish(body, result)
  def finish(%{action: %{kind: :wall_slide}} = body, result), do: WallSlide.finish(body, result)
  def finish(%{action: %{kind: :slide}} = body, result), do: Slide.finish(body, result)
  def finish(body, result), do: Climb.finish(body, result)
end
