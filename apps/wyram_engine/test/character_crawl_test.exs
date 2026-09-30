defmodule Wyram.Engine.CharacterCrawlTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "crawl crosses a one-block tunnel and a negative chunk seam without displacement snaps" do
    solid = fn {_, y, _} -> y < 0 or y == 1 end
    body = %{State.new(Profile.default(), {-15.9, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | crawling: true, sneaking: true, running: true, right: -1.0}
    next = Enum.reduce(1..100, body, fn _, body -> advance(body, input, solid) end)
    assert next.posture == :prone
    assert next.mode == :crawl
    assert next.height == 0.6
    assert next.eye_height == 0.45
    assert_in_delta elem(next.position, 0), -17.9, 1.0e-8
    assert elem(next.position, 1) == 0.0
    refute next.unavailable
  end

  test "blocked release remains prone; explicit crouch and clear standing expand at the feet" do
    body = State.new(Profile.default(), {0.5, 0.0, 0.5})
    tunnel = fn {_, y, _} -> y < 0 or y == 1 end
    prone = advance(body, %{Input.idle() | crawling: true}, tunnel)
    released = advance(prone, Input.idle(), tunnel)
    assert released.posture == :prone
    crouch = advance(released, %{Input.idle() | sneaking: true}, tunnel)
    assert crouch.posture == :crouch
    assert crouch.position == released.position
    standing = advance(crouch, Input.idle(), fn {_, y, _} -> y < 0 end)
    assert standing.posture == :stand
    assert standing.position == crouch.position
  end

  test "crawling cannot move through a solid voxel step" do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | crawling: true, right: 1.0}
    solid = fn {x, y, _} -> y < 0 or (x == 1 and y == 0) end
    next = Enum.reduce(1..100, body, fn _, body -> advance(body, input, solid) end)
    assert_in_delta elem(next.position, 0), 0.72, 1.0e-8
    assert next.grounded
  end

  defp advance(body, input, solid) do
    chunks =
      for x <- -2..0, y <- -1..0, z <- -1..0 do
        {{x, y, z}, chunk({x, y, z}, solid)}
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
