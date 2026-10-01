defmodule Wyram.Engine.CharacterPostureTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "sneaking shrinks at the feet and overrides running; blocked release retains crouch" do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | sneaking: true, running: true, forward: 1.0}
    crouch = advance(body, input, fn {_, y, _} -> y < 0 or y == 1 end)
    assert crouch.posture == :crouch
    assert crouch.mode == :sneak
    assert crouch.height == 1.0
    assert crouch.eye_height == 0.85
    assert elem(crouch.position, 1) == 0.0
    assert elem(crouch.velocity, 2) < 0
    assert abs(elem(crouch.velocity, 2)) < 2.0
    blocked = advance(crouch, Input.idle(), fn {_, y, _} -> y < 0 or y == 1 end)
    assert blocked.posture == :crouch
    standing = advance(blocked, Input.idle(), fn {_, y, _} -> y < 0 end)
    assert standing.posture == :stand
    assert standing.height == 1.8
  end

  test "sneaking protects cardinal and diagonal ledges across negative chunk coordinates" do
    for {x, z, right, forward} <- [
          {0.75, 0.5, 1.0, 0.0},
          {-0.75, -0.5, -1.0, 0.0},
          {0.5, 0.25, 0.0, 1.0},
          {-0.5, -0.25, 0.0, -1.0},
          {0.75, 0.25, 1.0, 1.0}
        ] do
      body = %{State.new(Profile.default(), {x, 0.0, z}) | grounded: true}
      input = %{Input.idle() | sneaking: true, right: right, forward: forward}
      solid = fn {bx, by, bz} -> by == -1 and bx in -1..0 and bz in -1..0 end
      stopped = Enum.reduce(1..100, body, fn _, b -> advance(b, input, solid) end)
      assert stopped.grounded
      assert elem(stopped.position, 1) == 0.0
      assert abs(elem(stopped.position, 0)) < 1.3
      assert abs(elem(stopped.position, 2)) < 1.3
    end
  end

  test "intentional jump can leave a ledge while airborne crouch stays safe" do
    body = %{State.new(Profile.default(), {1.2, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | sneaking: true, right: 1.0, jump: true}
    next = advance(body, input, fn {x, y, z} -> y == -1 and x == 0 and z == 0 end)
    assert elem(next.position, 0) > 1.2
    assert next.jump_pending != nil
    next = advance(next, input, fn {_, y, _} -> y < 0 end)
    assert elem(next.position, 1) > 0.0
    refute next.grounded
    assert next.posture == :crouch
  end

  defp advance(body, input, solid) do
    chunks =
      for x <- -1..0, y <- -1..0, z <- -1..0 do
        data = chunk({x, y, z}, solid)
        {{x, y, z}, data}
      end

    {:ok, bodies} = Step.advance([{"player", body, input}], &Native.sweep_bodies(chunks, &1))
    bodies["player"]
  end

  defp chunk({x, y, z}, solid) do
    for by <- 0..15, bz <- 0..15, bx <- 0..15, into: <<>> do
      id = if solid.({x * 16 + bx, y * 16 + by, z * 16 + bz}), do: 1, else: 0
      <<id::little-16>>
    end
  end
end
