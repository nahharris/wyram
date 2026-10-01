defmodule Wyram.Character.Roll do
  @moduledoc "Four-direction timed movement; cooldown and collision remain gameplay authority."
  alias Wyram.Character.State

  def choose(entries) do
    Enum.map(entries, fn {id, body, input} ->
      cooldown = max(0.0, body.roll_cooldown - State.tick_ms() / 1000)
      body = choose_body(%{body | roll_cooldown: cooldown}, input)
      {id, %{body | roll_held: input.rolling}, input}
    end)
  end

  defp choose_body(%{action: %{kind: :roll}} = body, input) do
    if interrupted?(input) or not body.grounded, do: %{body | action: nil}, else: body
  end

  defp choose_body(%{action: nil} = body, input) do
    if eligible?(body, input), do: enter(body, input), else: body
  end

  defp choose_body(body, _), do: body

  defp eligible?(b, i),
    do:
      b.profile.roll_enabled and b.grounded and b.roll_cooldown <= 0 and i.rolling and
        not b.roll_held and not interrupted?(i)

  defp interrupted?(i), do: i.cancel_actions or i.jump or i.crawling or i.climbing

  defp enter(body, input) do
    {forward, right, local} = local_direction(input)
    dx = :math.sin(input.yaw) * forward + :math.cos(input.yaw) * right
    dz = -:math.cos(input.yaw) * forward + :math.sin(input.yaw) * right
    {x, y, z} = body.position
    target = {x + dx * body.profile.roll_distance, y, z + dz * body.profile.roll_distance}

    action = %{
      kind: :roll,
      phase: :active,
      elapsed: 0.0,
      duration: body.profile.roll_duration,
      direction: {dx, dz},
      local_direction: local,
      target: target
    }

    %{body | action: action, roll_cooldown: body.profile.roll_cooldown}
  end

  defp local_direction(%{forward: forward, right: right}) when forward == 0 and right == 0,
    do: {1.0, 0.0, :forward}

  defp local_direction(input) do
    if abs(input.forward) >= abs(input.right) do
      if input.forward < 0, do: {-1.0, 0.0, :back}, else: {1.0, 0.0, :forward}
    else
      if input.right < 0, do: {0.0, -1.0, :left}, else: {0.0, 1.0, :right}
    end
  end

  def prepare(body, input) do
    {next, {position, {_, dy, _}, radius, height}} = State.prepare(body, input)
    dt = State.tick_ms() / 1000
    remaining = max(0.0, body.profile.roll_duration - body.action.elapsed)
    step = min(dt, remaining)
    speed = body.profile.roll_distance / body.profile.roll_duration
    {dx, dz} = body.action.direction
    action = %{body.action | elapsed: body.action.elapsed + step}

    next = %{
      next
      | action: action,
        mode: :roll,
        velocity: {dx * speed, elem(next.velocity, 1), dz * speed}
    }

    {next, {position, {dx * speed * step, dy, dz * speed * step}, radius, height}}
  end

  def finish(body, {_, {hit_x, _, hit_z}, unavailable} = result) do
    next = State.finish(body, result)
    done = body.action.elapsed >= body.profile.roll_duration - 1.0e-9

    if done or hit_x or hit_z or unavailable or not next.grounded,
      do: %{next | action: nil, velocity: {0.0, elem(next.velocity, 1), 0.0}},
      else: next
  end
end
