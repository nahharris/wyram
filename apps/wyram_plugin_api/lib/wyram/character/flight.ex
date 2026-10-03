defmodule Wyram.Character.Flight do
  @moduledoc "Opt-in collision-checked flight. Gesture requests are consumed once; ground contact restores walking."
  alias Wyram.Character.State
  @dt State.tick_ms() / 1000

  def begin(body, input) do
    fresh = input.flight_request > body.flight_request
    body = %{body | flight_request: max(body.flight_request, input.flight_request)}

    if fresh and body.mode != :fly and body.profile.fly_enabled and
         not input.cancel_actions and not body.unavailable do
      {vx, _, vz} = body.velocity

      %{
        body
        | mode: :fly,
          action: nil,
          grounded: false,
          jump_pending: nil,
          jump_origin: nil,
          velocity: {vx, if(body.grounded, do: min(2.0, body.profile.fly_speed), else: 0.0), vz}
      }
    else
      body
    end
  end

  def prepare(body, input) do
    vertical = if(input.jump, do: 1.0, else: 0.0) - if(input.sneaking, do: 1.0, else: 0.0)

    target = {
      :math.sin(input.yaw) * input.forward + :math.cos(input.yaw) * input.right,
      vertical,
      -:math.cos(input.yaw) * input.forward + :math.sin(input.yaw) * input.right
    }

    target =
      if input.cancel_actions,
        do: {0.0, 0.0, 0.0},
        else: scale(target, body.profile.fly_speed / max(1.0, magnitude(target)))

    delta = subtract(target, body.velocity)
    amount = min(1.0, body.profile.fly_acceleration * @dt / max(1.0e-9, magnitude(delta)))

    velocity =
      if input.cancel_actions, do: {0.0, 0.0, 0.0}, else: add(body.velocity, scale(delta, amount))

    next = %{
      body
      | velocity: velocity,
        mode: :fly,
        action: nil,
        jump_held: input.jump,
        jump_pending: nil,
        jump_origin: nil,
        yaw: input.yaw,
        pitch: input.pitch,
        input_sequence: input.sequence,
        transition: :air,
        transition_time: 0.0
    }

    {next, {body.position, scale(velocity, @dt), body.radius, body.height}}
  end

  def landed(%{mode: :fly} = body, true) do
    {vx, _, vz} = body.velocity
    velocity = {vx, 0.0, vz}

    velocity =
      scale(velocity, min(1.0, body.profile.walk_speed / max(1.0e-9, magnitude(velocity))))

    %{
      body
      | mode: :walk,
        velocity: velocity,
        action: nil,
        jump_pending: nil,
        jump_origin: nil,
        transition: :landing,
        transition_time: body.profile.landing_duration
    }
  end

  def landed(body, _), do: body

  def ground(bodies, collision) do
    flying =
      Enum.filter(bodies, fn {_, b} ->
        b.mode == :fly and not b.unavailable and elem(b.velocity, 1) <= 0
      end)

    if flying == [] do
      {:ok, bodies}
    else
      queries =
        Enum.map(flying, fn {_, b} -> {b.position, {0.0, -0.001, 0.0}, b.radius, b.height} end)

      with {:ok, results} <- collision.(queries) do
        {:ok,
         Enum.zip(flying, results)
         |> Enum.reduce(bodies, fn {{id, b}, result}, acc ->
           Map.put(acc, id, support(b, result))
         end)}
      end
    end
  end

  defp support(body, {_, {_, true, _}, false}), do: %{landed(body, true) | grounded: true}
  defp support(body, {_, _, true}), do: %{body | velocity: {0.0, 0.0, 0.0}, unavailable: true}
  defp support(body, _), do: body
  defp magnitude({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)
  defp scale({x, y, z}, s), do: {x * s, y * s, z * s}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
end
