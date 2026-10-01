defmodule Wyram.Character.Motion do
  @moduledoc "Fixed-step acceleration and short movement transitions without presentation authority."
  alias Wyram.Character.State
  @dt State.tick_ms() / 1000

  def prepare(body, input, motion) do
    {vx, vz} = horizontal(body, input, motion.speed)
    {pending, launch} = jump(body, input)
    initial_vy = if launch, do: motion.jump_speed, else: elem(body.velocity, 1)
    vy = max(initial_vy - motion.gravity * @dt, -motion.terminal_speed)
    {phase, time} = transition(body, pending, launch, vx, vz, input)

    next = %{
      body
      | velocity: {vx, vy, vz},
        jump_pending: pending,
        jump_origin: if(launch, do: body.position, else: body.jump_origin),
        transition: phase,
        transition_time: time,
        last_posture: body.posture,
        jump_held: input.jump,
        mode: motion.mode,
        yaw: input.yaw,
        pitch: input.pitch,
        input_sequence: input.sequence
    }

    {next,
     {body.position, {vx * @dt, (initial_vy + vy) * 0.5 * @dt, vz * @dt}, body.radius,
      body.height}}
  end

  def landed(body, grounded) do
    if grounded and not body.grounded do
      %{
        body
        | jump_origin: nil,
          jump_pending: nil,
          transition: :landing,
          transition_time: body.profile.landing_duration
      }
    else
      body
    end
  end

  defp horizontal(body, input, speed) do
    if input.cancel_actions do
      {0.0, 0.0}
    else
      length = max(1.0, :math.sqrt(input.forward * input.forward + input.right * input.right))

      x =
        (:math.sin(input.yaw) * input.forward + :math.cos(input.yaw) * input.right) / length *
          speed

      z =
        (-:math.cos(input.yaw) * input.forward + :math.sin(input.yaw) * input.right) / length *
          speed

      {vx, _, vz} = body.velocity
      rate = acceleration(body, x, z, vx, vz)
      dx = x - vx
      dz = z - vz
      factor = min(1.0, rate * @dt / max(1.0e-9, :math.sqrt(dx * dx + dz * dz)))
      capped({vx + dx * factor, vz + dz * factor}, body.posture, speed)
    end
  end

  defp acceleration(body, x, z, vx, vz) do
    cond do
      not body.grounded -> body.profile.air_acceleration
      x * x + z * z < vx * vx + vz * vz -> body.profile.ground_deceleration
      true -> body.profile.ground_acceleration
    end
  end

  defp capped({x, z}, posture, speed) when posture in [:crouch, :prone] do
    scale = min(1.0, speed / max(1.0e-9, :math.sqrt(x * x + z * z)))
    {x * scale, z * scale}
  end

  defp capped(velocity, _, _), do: velocity

  defp jump(body, input) do
    pending =
      if body.grounded and input.jump and not body.jump_held,
        do: body.profile.jump_delay,
        else: body.jump_pending

    cond do
      input.cancel_actions or not body.grounded -> {nil, false}
      pending == nil -> {nil, false}
      pending <= @dt + 1.0e-9 -> {nil, true}
      true -> {pending - @dt, false}
    end
  end

  defp transition(body, pending, launch, vx, vz, input) do
    cond do
      pending != nil -> {:jump_start, body.profile.jump_delay}
      launch -> {:takeoff, 0.08}
      body.posture != body.last_posture -> {:posture, 0.1}
      body.transition_time > @dt -> {body.transition, body.transition_time - @dt}
      true -> steady_transition(body, vx, vz, input)
    end
  end

  defp steady_transition(body, vx, vz, input) do
    cond do
      not body.grounded -> {:air, 0.0}
      vx * vx + vz * vz < 1.0e-8 -> {:idle, 0.0}
      input.forward == 0 and input.right == 0 -> {:stop, 0.0}
      true -> {:move, 0.0}
    end
  end
end
