defmodule Wyram.Character.Actions do
  @moduledoc "Shared action dispatch keeps character ownership independent of each traversal policy."
  alias Wyram.Character.{Climb, Slide}
  def choose(entries, collision), do: entries |> Slide.choose() |> Climb.choose(collision)
  def prepare(%{action: %{kind: :slide}} = body, input), do: Slide.prepare(body, input)
  def prepare(body, input), do: Climb.prepare(body, input)
  def finish(%{action: %{kind: :slide}} = body, result), do: Slide.finish(body, result)
  def finish(body, result), do: Climb.finish(body, result)
end
