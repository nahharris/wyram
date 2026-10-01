defmodule Wyram.Engine.CharacterJumpTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "one-block obstacles land cleanly at 30/60/144 Hz and through a presentation stall" do
    assert State.tick_ms() == 20

    for diagonal <- [false, true] do
      collision = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y == 0) end)
      input = %{Input.idle() | right: 1.0, forward: if(diagonal, do: 1.0, else: 0.0), jump: true}
      paths = for rate <- [30, 60, 144], do: replay(frames(rate), input, collision)
      assert Enum.uniq(paths) |> length() == 1
      {body, apex} = hd(paths)
      assert body.grounded
      assert elem(body.position, 0) > 1.28
      assert_in_delta elem(body.position, 1), 1.0, 1.0e-9
      assert apex > 1 and apex < 2
      assert replay([0, 200, 900, 1000], input, collision) == hd(paths)
    end
  end

  test "the default jump cannot clear two blocks, and ceilings cancel ascent" do
    input = %{Input.idle() | right: 1.0, jump: true}
    wall = terrain(fn {x, y, _} -> y < 0 or (x >= 1 and y in 0..1) end)
    {stopped, apex} = replay(frames(60), input, wall)
    assert_in_delta elem(stopped.position, 0), 0.72, 1.0e-8
    assert_in_delta elem(stopped.position, 1), 0.0, 1.0e-9
    assert stopped.grounded
    assert apex < 2
    ceiling = terrain(fn {_, y, _} -> y < 0 or y == 2 end)
    {under, apex} = replay(frames(60), %{input | right: 0.0}, ceiling)
    assert apex <= 0.2 + 1.0e-8
    assert under.grounded
  end

  test "no coyote or buffered jump, no airborne repeat, and re-press after landing jumps" do
    collision = terrain(fn {_, y, _} -> y < 0 end)
    body = %{State.new(%{Profile.default() | climb_height: 0}, {0.5, 0.0, 0.5}) | grounded: true}
    jump = %{Input.idle() | jump: true}
    waiting = step(body, jump, collision)
    assert waiting.grounded
    ascending = step(waiting, jump, collision)
    assert elem(ascending.velocity, 1) > 0
    released = step(ascending, Input.idle(), collision)
    repeated = step(released, jump, collision)
    assert elem(repeated.velocity, 1) < elem(released.velocity, 1)
    landed = Enum.reduce(1..60, repeated, fn _, b -> step(b, jump, collision) end)
    assert landed.grounded
    assert_in_delta elem(landed.position, 1), 0.0, 1.0e-9
    waiting = step(landed, Input.idle(), collision)
    charged = step(waiting, jump, collision)
    assert elem(step(charged, jump, collision).velocity, 1) > 0
    airborne = %{body | position: {0.5, 0.5, 0.5}, grounded: false}
    assert elem(step(airborne, jump, collision).velocity, 1) < 0
    buffered = Enum.reduce(1..60, airborne, fn _, b -> step(b, jump, collision) end)
    assert buffered.grounded
    assert_in_delta elem(buffered.position, 1), 0.0, 1.0e-9
  end

  defp frames(rate), do: for(frame <- 0..rate, do: div(frame * 1000, rate))

  defp replay(frames, input, collision) do
    initial = %{
      State.new(%{Profile.default() | climb_height: 0}, {0.5, 0.0, 0.5})
      | grounded: true
    }

    {body, apex, _} =
      Enum.reduce(frames, {initial, 0.0, 0}, fn ms, {body, apex, previous} ->
        target = div(ms, 20)
        {body, apex} = ticks(body, apex, target - previous, input, collision)
        {body, apex, target}
      end)

    {body, apex}
  end

  defp ticks(body, apex, 0, _, _), do: {body, apex}

  defp ticks(body, apex, count, input, collision) do
    next = step(body, input, collision)
    ticks(next, max(apex, elem(next.position, 1)), count - 1, input, collision)
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
