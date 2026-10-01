defmodule Wyram.Engine.CharacterFeelTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}
  alias Wyram.Engine.Native

  test "start and stop take a few fixed steps without a speed discontinuity" do
    ground = collision(0)
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    walk = %{Input.idle() | right: 1.0}
    first = step(body, walk, ground)
    assert elem(first.velocity, 0) > 0 and elem(first.velocity, 0) < 2
    moving = Enum.reduce(1..12, first, fn _, b -> step(b, walk, ground) end)
    assert_in_delta elem(moving.velocity, 0), 5, 1.0e-8
    stopping = step(moving, Input.idle(), ground)
    assert elem(stopping.velocity, 0) > 0 and elem(stopping.velocity, 0) < 5
    stopped = Enum.reduce(1..12, stopping, fn _, b -> step(b, Input.idle(), ground) end)
    assert_in_delta elem(stopped.velocity, 0), 0, 1.0e-8
    crawl = step(moving, %{walk | crawling: true, running: true}, ground)
    assert abs(elem(crawl.velocity, 0)) <= crawl.profile.crawl_speed
    assert crawl.profile.crawl_speed < crawl.profile.sneak_speed / 2
  end

  test "jump has a brief windup, clears one block and returns within 600 milliseconds" do
    ground = collision(0)
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    jump = %{Input.idle() | jump: true}
    first = step(body, jump, ground)
    assert first.grounded

    {last, history} =
      Enum.reduce(1..30, {first, [first]}, fn _, {b, h} ->
        n = step(b, jump, ground)
        {n, [n | h]}
      end)

    assert Enum.any?(history, &(elem(&1.position, 1) > 1.0))
    assert Enum.max_by(history, &elem(&1.position, 1)) |> Map.fetch!(:position) |> elem(1) < 1.4
    assert last.grounded
    assert Enum.count(history, &(not &1.grounded)) < 29
    assert Enum.any?(history, &(Map.get(State.snapshot(&1), :transition) == :landing))
  end

  test "held Space climbs two and three blocks only after jumping into a nearby obstacle" do
    for height <- [2, 3] do
      ground = collision(height)
      body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
      input = %{Input.idle() | jump: true, right: 1.0}

      {landed, history} =
        Enum.reduce(1..110, {body, []}, fn _, {b, h} ->
          n = step(b, input, ground)
          {n, [n | h]}
        end)

      assert Enum.any?(history, &(&1.mode == :climb))
      assert elem(landed.position, 1) == height
      assert landed.grounded
      assert landed.action == nil
      assert Enum.count(history, &match?(%{kind: :climb, phase: :rise}, &1.action)) > 1
    end

    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | jump: true, right: 1.0}
    history = Enum.scan(1..60, body, fn _, b -> step(b, input, collision(0)) end)
    refute Enum.any?(history, &(&1.mode == :climb))
    tall = Enum.reduce(1..80, body, fn _, b -> step(b, input, collision(4)) end)
    assert_in_delta elem(tall.position, 1), 0.0, 1.0e-8
  end

  test "releasing Space or requesting crawl interrupts an assisted climb, and a roof rejects it" do
    wall = collision(3)
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    jump = %{Input.idle() | jump: true, right: 1.0}

    active =
      Enum.reduce_while(1..30, body, fn _, b ->
        n = step(b, jump, wall)
        if n.action, do: {:halt, n}, else: {:cont, n}
      end)

    assert active.action.kind == :climb
    assert step(active, %{jump | jump: false}, wall).action == nil
    assert step(active, %{jump | crawling: true}, wall).action == nil
    unknown = step(active, jump, &Native.sweep_bodies([], &1))
    assert unknown.unavailable and unknown.action == nil
    roof = collision(3, true)
    stopped = Enum.reduce(1..70, body, fn _, b -> step(b, jump, roof) end)
    refute stopped.action
    assert elem(stopped.position, 0) <= 0.72 + 1.0e-8
  end

  defp step(body, input, collision) do
    {:ok, bodies} = Step.advance([{"player", body, input}], collision)
    bodies["player"]
  end

  defp collision(height, roof \\ false) do
    chunks = for x <- -1..0, y <- -1..0, z <- -1..0, do: chunk(x, y, z, height, roof)
    &Native.sweep_bodies(chunks, &1)
  end

  defp chunk(x, y, z, height, roof) do
    data =
      for by <- 0..15, _bz <- 0..15, bx <- 0..15, into: <<>> do
        wx = x * 16 + bx
        wy = y * 16 + by

        id =
          if wy < 0 or (height > 0 and wx >= 1 and wy < height) or (roof and wy == 3),
            do: 1,
            else: 0

        <<id::little-16>>
      end

    {{x, y, z}, data}
  end
end
