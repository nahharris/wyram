defmodule Wyram.Engine.CharacterRollTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "four relative directions travel the profile distance independently of facing" do
    collision = terrain(fn {_, y, _} -> y < 0 end)

    for yaw <- [0.0, :math.pi() / 2],
        {forward, right, local} <- [
          {1.0, 0.0, :forward},
          {-1.0, 0.0, :back},
          {0.0, -1.0, :left},
          {0.0, 1.0, :right}
        ] do
      body = initial()
      input = %{Input.idle() | rolling: true, forward: forward, right: right, yaw: yaw}
      active = step(body, input, collision)
      assert active.action.local_direction == local
      assert active.posture == :prone
      # Key release does not cancel a committed roll.
      next =
        Enum.reduce(1..17, active, fn _, body ->
          step(body, %{input | rolling: false}, collision)
        end)

      assert next.action == nil
      x = :math.sin(yaw) * forward + :math.cos(yaw) * right
      z = -:math.cos(yaw) * forward + :math.sin(yaw) * right
      assert_in_delta elem(next.position, 0), 0.5 + x * 3, 1.0e-8
      assert_in_delta elem(next.position, 2), 0.5 + z * 3, 1.0e-8
      assert next.grounded
    end
  end

  test "dominant direction resolves diagonals; held input and cooldown prevent repeats" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    input = %{Input.idle() | rolling: true, forward: 1.0, right: 1.0}
    assert step(initial(), input, collision).action.local_direction == :forward
    pressed = %{Input.idle() | rolling: true}
    held = Enum.reduce(1..100, initial(), fn _, body -> step(body, pressed, collision) end)
    assert held.action == nil
    assert_in_delta elem(held.position, 2), -2.5, 1.0e-8
    released = step(held, Input.idle(), collision)
    assert step(released, pressed, collision).action != nil
    active = step(initial(), pressed, collision)
    interrupted = step(active, %{Input.idle() | cancel_actions: true}, collision)
    assert interrupted.action == nil
    assert step(interrupted, pressed, collision).action == nil
  end

  test "walls and ledges interrupt; tunnels permit rolling but block standing on exit" do
    input = %{Input.idle() | rolling: true, right: 1.0}

    for solid <- [
          fn {x, y, _} -> y < 0 or (x == 1 and y == 0) end,
          fn {x, y, _} -> y == -1 and x == 0 end
        ] do
      collision = terrain(solid)
      active = step(initial(), input, collision)

      stopped =
        Enum.reduce(1..17, active, fn _, body ->
          step(body, %{Input.idle() | rolling: true}, collision)
        end)

      assert stopped.action == nil
      assert stopped.grounded
      assert elem(stopped.position, 0) < 1.3
    end

    tunnel = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y == 1) end)
    active = step(initial(), input, tunnel)
    completed = Enum.reduce(1..17, active, fn _, body -> step(body, Input.idle(), tunnel) end)
    assert_in_delta elem(completed.position, 0), 3.5, 1.0e-8
    released = step(completed, Input.idle(), tunnel)
    assert released.posture == :prone
    assert released.action == nil
  end

  test "jump/focus cancellation, disabled capability and unavailable terrain are safe" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    pressed = %{Input.idle() | rolling: true}
    active = step(initial(), pressed, collision)
    assert {:ok, _} = Jason.encode(State.snapshot(active))
    jumped = step(active, %{Input.idle() | jump: true}, collision)
    assert jumped.action == nil
    assert jumped.jump_pending != nil
    assert elem(step(jumped, %{Input.idle() | jump: true}, collision).velocity, 1) > 0
    cancelled = step(active, %{Input.idle() | cancel_actions: true}, collision)
    assert cancelled.action == nil
    disabled = %{initial() | profile: %{Profile.default() | roll_enabled: false}}
    assert step(disabled, pressed, collision).action == nil
    unknown = step(initial(), pressed, &Native.sweep_bodies([], &1))
    assert unknown.unavailable
    assert unknown.action == nil
    assert unknown.position == initial().position
  end

  test "custom distance and duration remain exact across render schedules" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    body = %{initial() | profile: %{Profile.default() | roll_distance: 2.0, roll_duration: 0.4}}
    input = %{Input.idle() | rolling: true}

    replays =
      for rate <- [30, 60, 144] do
        {body, _} =
          Enum.reduce(0..rate, {body, 0}, fn frame, {body, previous} ->
            target = div(frame * 50, rate)
            {ticks(body, target - previous, input, collision), target}
          end)

        body
      end

    assert length(Enum.uniq(replays)) == 1
    assert_in_delta elem(hd(replays).position, 2), -1.5, 1.0e-8
    assert hd(replays).action == nil
  end

  defp ticks(body, 0, _, _), do: body

  defp ticks(body, count, input, collision),
    do: ticks(step(body, input, collision), count - 1, input, collision)

  defp initial, do: %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}

  defp step(body, input, collision) do
    {:ok, bodies} = Step.advance([{"player", body, input}], collision)
    bodies["player"]
  end

  defp terrain(solid) do
    chunks = for x <- -1..0, y <- -1..0, z <- -1..0, do: {{x, y, z}, chunk({x, y, z}, solid)}
    &Native.sweep_bodies(chunks, &1)
  end

  defp chunk({x, y, z}, solid) do
    for by <- 0..15, bz <- 0..15, bx <- 0..15, into: <<>> do
      id = if solid.({x * 16 + bx, y * 16 + by, z * 16 + bz}), do: 1, else: 0
      <<id::little-16>>
    end
  end
end
