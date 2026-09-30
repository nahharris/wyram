defmodule Wyram.Engine.CharacterWallSlideTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "deliberate descending contact caps fall speed on each wall direction" do
    for {position, right, forward, axis, direction} <- [
          {{0.72, 3.0, 0.5}, 1.0, 0.0, 0, 1},
          {{0.28, 3.0, 0.5}, -1.0, 0.0, 0, -1},
          {{0.5, 3.0, 0.28}, 0.0, 1.0, 2, -1},
          {{0.5, 3.0, 0.72}, 0.0, -1.0, 2, 1}
        ] do
      collision =
        terrain(fn cell ->
          elem(cell, 1) < 0 or (wall?(elem(cell, axis), direction) and elem(cell, 1) < 6)
        end)

      body = %{State.new(Profile.default(), position) | velocity: {0.0, -10.0, 0.0}}
      input = %{Input.idle() | sneaking: true, right: right, forward: forward}
      next = Enum.reduce(1..5, body, fn _, body -> step(body, input, collision) end)
      assert next.mode == :wall_slide
      assert elem(next.velocity, 1) == -2.0
      assert_in_delta elem(next.position, 1), 2.8, 1.0e-8
      assert next.action.kind == :wall_slide
    end
  end

  test "removed wall, released pressure and released Shift restore ordinary falling" do
    collision = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y < 6) end)
    body = %{State.new(Profile.default(), {0.72, 3.0, 0.5}) | velocity: {0.0, -10.0, 0.0}}
    input = %{Input.idle() | sneaking: true, right: 1.0}
    active = step(body, input, collision)

    for {intent, world} <- [
          {input, terrain(fn {_, y, _} -> y < 0 end)},
          {%{input | right: -1.0}, collision},
          {Input.idle(), collision}
        ] do
      next = step(active, intent, world)
      assert next.action == nil
      assert elem(next.velocity, 1) < -2.0
    end
  end

  test "corners remain stable, landing exits, ascending contact does not activate, and capabilities apply" do
    collision = terrain(fn {x, y, z} -> y < 0 or ((x >= 1 or z >= 1) and y < 6) end)
    body = %{State.new(Profile.default(), {0.72, 3.0, 0.72}) | velocity: {0.0, -10.0, 0.0}}
    input = %{Input.idle() | sneaking: true, right: 1.0, forward: -1.0}
    active = step(body, input, collision)
    assert active.mode == :wall_slide
    landed = Enum.reduce(1..200, active, fn _, body -> step(body, input, collision) end)
    assert landed.grounded
    assert landed.action == nil
    assert_in_delta elem(landed.position, 1), 0.0, 1.0e-8
    ascending = step(%{body | velocity: {0.0, 3.0, 0.0}}, input, collision)
    assert ascending.action == nil
    disabled = %{body | profile: %{body.profile | wall_slide_enabled: false}}
    assert step(disabled, input, collision).action == nil
    custom = %{body | profile: %{body.profile | wall_slide_speed: 1.0}}
    assert elem(step(custom, input, collision).velocity, 1) == -1.0
    unknown = step(body, input, &Native.sweep_bodies([], &1))
    assert unknown.action == nil
    assert unknown.unavailable
    assert unknown.position == body.position
  end

  test "ceiling hits cancel ascent before deliberate descent can engage" do
    collision = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y < 6) or y == 4 end)
    body = %{State.new(Profile.default(), {0.72, 3.0, 0.5}) | velocity: {0.0, 3.0, 0.0}}
    input = %{Input.idle() | sneaking: true, right: 1.0}
    ceiling = step(body, input, collision)
    assert ceiling.action == nil
    assert elem(ceiling.velocity, 1) == 0.0
    falling = step(ceiling, input, collision)
    assert falling.mode == :wall_slide
    assert elem(falling.velocity, 1) < 0
    assert elem(falling.velocity, 1) >= -2.0
  end

  defp wall?(value, 1), do: value >= 1
  defp wall?(value, -1), do: value <= -1

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
