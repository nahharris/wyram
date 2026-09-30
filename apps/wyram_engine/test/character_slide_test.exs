defmodule Wyram.Engine.CharacterSlideTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "run-to-crouch enters a finite momentum slide, with slow entry rejected" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    body = running(collision)
    input = %{Input.idle() | right: 1.0, running: true, sneaking: true}
    active = step(body, input, collision)
    assert active.mode == :slide
    assert active.posture == :crouch
    assert elem(active.velocity, 0) > Profile.default().sneak_speed
    assert {:ok, _} = Jason.encode(State.snapshot(active))
    finished = Enum.reduce(1..60, active, fn _, body -> step(body, input, collision) end)
    assert finished.action == nil
    assert finished.mode == :sneak
    slow = %{body | velocity: {2.0, 0.0, 0.0}}
    assert step(slow, input, collision).action == nil
  end

  test "walls and ledges interrupt without tunneling or falling; low tunnel exit stays crouched" do
    input = %{Input.idle() | right: 1.0, running: true, sneaking: true}

    for solid <- [
          fn {x, y, _} -> y < 0 or (x == 1 and y == 0) end,
          fn {x, y, _} -> y == -1 and x == 0 end
        ] do
      collision = terrain(solid)

      body = %{
        State.new(Profile.default(), {0.5, 0.0, 0.5})
        | grounded: true,
          mode: :run,
          velocity: {9.0, 0.0, 0.0}
      }

      stopped = Enum.reduce(1..20, body, fn _, body -> step(body, input, collision) end)
      assert stopped.action == nil
      assert stopped.grounded
      assert_in_delta elem(stopped.position, 1), 0.0, 1.0e-8
      assert elem(stopped.position, 0) < 1.3
    end

    tunnel = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y == 1) end)
    body = running(terrain(fn {_, y, _} -> y < 0 end))
    active = Enum.reduce(1..5, body, fn _, body -> step(body, input, tunnel) end)
    assert elem(active.position, 0) > 1.28
    assert active.action != nil
    released = step(active, Input.idle(), tunnel)
    assert released.action == nil
    assert released.posture == :crouch
  end

  test "jump and loss of input cancel sliding while custom profiles can disable it" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    body = running(collision)
    input = %{Input.idle() | right: 1.0, running: true, sneaking: true}
    active = step(body, input, collision)
    released = step(active, Input.idle(), collision)
    assert released.action == nil
    assert released.posture == :stand
    jumped = step(active, %{input | jump: true}, collision)
    assert jumped.action == nil
    assert elem(jumped.velocity, 1) > 0
    disabled = %{body | profile: %{body.profile | slide_enabled: false}}
    assert step(disabled, input, collision).action == nil
  end

  test "slide duration and displacement do not depend on presentation frames" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    input = %{Input.idle() | right: 1.0, running: true, sneaking: true}
    initial = running(collision)

    replays =
      for rate <- [30, 60, 144] do
        {body, _} =
          Enum.reduce(0..rate, {initial, 0}, fn frame, {body, previous} ->
            target = div(frame * 50, rate)
            {ticks(body, target - previous, input, collision), target}
          end)

        body
      end

    assert length(Enum.uniq(replays)) == 1
    assert hd(replays).action == nil
  end

  defp ticks(body, 0, _, _), do: body

  defp ticks(body, count, input, collision),
    do: ticks(step(body, input, collision), count - 1, input, collision)

  defp running(collision) do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    step(body, %{Input.idle() | right: 1.0, running: true}, collision)
  end

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
