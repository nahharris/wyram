defmodule Wyram.Engine.CharacterClimbTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "deliberate climbs sweep to supported one/two/three-block ledges in all directions" do
    for height <- 1..3,
        {right, forward, axis, direction} <- [
          {1.0, 0.0, 0, 1},
          {-1.0, 0.0, 0, -1},
          {0.0, 1.0, 2, -1},
          {0.0, -1.0, 2, 1}
        ] do
      solid = fn cell ->
        elem(cell, 1) < 0 or (on_ledge?(elem(cell, axis), direction) and elem(cell, 1) < height)
      end

      collision = terrain(solid)
      body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
      input = %{Input.idle() | climbing: true, right: right, forward: forward}

      {landed, history} =
        Enum.reduce(1..100, {body, []}, fn _, {body, history} ->
          next = step(body, input, collision)
          {next, [next | history]}
        end)

      assert_in_delta elem(landed.position, 1), height, 1.0e-8
      assert landed.grounded
      assert landed.action == nil
      assert Enum.any?(history, &(&1.mode == :climb))

      for b <- history do
        assert {:ok, [{_, {false, false, false}, false}]} =
                 collision.([{b.position, {0.0, 0.0, 0.0}, b.radius, b.height}])
      end

      for [after_step, before_step] <-
            Enum.chunk_every([body | Enum.reverse(history)], 2, 1, :discard) do
        assert distance(after_step.position, before_step.position) < 0.3
      end
    end
  end

  test "ceilings, unsupported corners and unknown terrain reject entry" do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | climbing: true, right: 1.0}
    ceiling = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y < 3) or y == 3 end)
    assert step(body, input, ceiling).action == nil
    empty = terrain(fn {_, y, _} -> y < 0 end)
    assert step(body, input, empty).action == nil
    unknown = &Native.sweep_bodies([], &1)
    frozen = step(body, input, unknown)
    assert frozen.action == nil
    assert frozen.unavailable
    assert frozen.position == body.position
  end

  test "release and removed landing support cancel the traversal without snapping" do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    wall = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y < 3) end)
    input = %{Input.idle() | climbing: true, right: 1.0}
    active = step(body, input, wall)
    assert active.action != nil
    assert {:ok, _} = Jason.encode(State.snapshot(active))
    released = step(active, Input.idle(), wall)
    assert released.action == nil
    assert distance(released.position, active.position) < 0.2
    removed = step(active, input, terrain(fn {_, y, _} -> y < 0 end))
    assert removed.action == nil
  end

  test "per-character climb capabilities and repeated input obey entry rules" do
    collision = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y < 2) end)
    input = %{Input.idle() | climbing: true, right: 1.0}

    disabled = %{
      State.new(%{Profile.default() | climb_height: 0}, {0.5, 0.0, 0.5})
      | grounded: true
    }

    assert step(disabled, input, collision).action == nil
    short = %{State.new(%{Profile.default() | climb_height: 1}, {0.5, 0.0, 0.5}) | grounded: true}
    assert step(short, input, collision).action == nil
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    active = step(body, input, collision)
    interrupted = step(active, %{input | sneaking: true}, collision)
    assert interrupted.action == nil
    assert interrupted.posture == :crouch
    held = %{body | climb_held: true}
    assert step(held, input, collision).action == nil
    airborne = %{body | grounded: false}
    assert step(airborne, input, collision).action == nil
  end

  defp on_ledge?(value, 1), do: value >= 1
  defp on_ledge?(value, -1), do: value <= -1

  defp distance({x, y, z}, {a, b, c}),
    do: :math.sqrt((x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c))

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
