defmodule Wyram.Character.Slide do
  @moduledoc "Finite crouched momentum with per-character entry, friction and interruption rules."
  alias Wyram.Character.State

  def choose(entries) do
    Enum.map(entries, fn {id, body, input} -> {id, choose_body(body, input), input} end)
  end

  defp choose_body(%{action: %{kind: :slide}} = body, input) do
    if held?(input) and body.grounded, do: body, else: %{body | action: nil}
  end

  defp choose_body(%{action: nil} = body, input) do
    if eligible?(body, input), do: %{body | action: action(body)}, else: body
  end

  defp choose_body(body, _), do: body

  defp eligible?(body, input),
    do:
      body.profile.slide_enabled and body.grounded and body.mode == :run and held?(input) and
        speed(body.velocity) >= body.profile.slide_entry_speed

  defp held?(i), do: i.running and i.sneaking and not i.jump and not i.crawling and not i.climbing
  defp speed({x, _, z}), do: :math.sqrt(x * x + z * z)

  defp action(body) do
    {x, _, z} = body.velocity
    speed = speed(body.velocity)
    %{kind: :slide, phase: :active, elapsed: 0.0, speed: speed, direction: {x / speed, z / speed}}
  end

  def prepare(body, input) do
    {next, {position, {_, dy, _}, radius, height}} = State.prepare(body, input)
    dt = State.tick_ms() / 1000
    speed = max(0.0, body.action.speed - body.profile.slide_friction * dt)
    average = (body.action.speed + speed) * 0.5
    {dx, dz} = body.action.direction
    vx = dx * average
    vz = dz * average
    action = %{body.action | speed: speed, elapsed: body.action.elapsed + dt}
    next = %{next | velocity: {vx, elem(next.velocity, 1), vz}, mode: :slide, action: action}
    {next, {position, {vx * dt, dy, vz * dt}, radius, height}}
  end

  def finish(body, {_, {hit_x, _, hit_z}, unavailable} = result) do
    next = State.finish(body, result)
    done = body.action.elapsed >= body.profile.slide_duration or body.action.speed <= 0

    if done or hit_x or hit_z or unavailable or not next.grounded,
      do: %{next | action: nil},
      else: next
  end
end
