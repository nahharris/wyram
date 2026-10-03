defmodule Wyram.Character.FlightTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State, Step}

  test "flight requests are bounded sequenced intent and survive release" do
    packet =
      %{Input.idle() | sequence: 1}
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.put("flight_request", 3)

    assert {:ok, input} = Input.decode(packet)
    assert Map.get(input, :flight_request) == 3
    assert Map.get(Input.release(input), :flight_request) == 3
    assert {:error, :invalid_input} = Input.decode(Map.put(packet, "flight_request", -1))
  end

  test "fresh flight intent opts enabled characters into collision checked hovering" do
    profile = Map.put(Profile.default(), :fly_enabled, true)
    body = State.new(profile, {0.5, 20.0, 0.5})
    input = Map.put(Input.idle(), :flight_request, 1)
    {next, {_, delta, _, _}} = State.prepare(body, input)
    assert next.mode == :fly
    assert delta == {0.0, 0.0, 0.0}
    assert next.velocity == {0.0, 0.0, 0.0}
  end

  test "single jumps and disabled profiles retain ordinary movement" do
    body = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    {ordinary, _} = State.prepare(body, Map.put(%{Input.idle() | jump: true}, :flight_request, 1))
    assert ordinary.mode == :walk
    assert ordinary.jump_pending != nil
    enabled = %{body | profile: Map.put(body.profile, :fly_enabled, true)}
    {jumping, _} = State.prepare(enabled, %{Input.idle() | jump: true})
    assert jumping.mode == :walk
  end

  test "flight tuning rejects invalid flags and speeds" do
    for {key, value} <- [fly_enabled: "yes", fly_speed: 0, fly_speed: 101, fly_acceleration: 0] do
      assert {:error, :invalid_character_profile} =
               Profile.validate(Map.put(Profile.default(), key, value))
    end
  end

  test "flight normalizes three dimensional movement and Shift descends without crouching" do
    body = %{
      State.new(Map.put(Profile.default(), :fly_enabled, true), {0.5, 20.0, 0.5})
      | mode: :fly
    }

    input = Map.merge(Input.idle(), %{jump: true, forward: 1.0, right: 1.0})

    body =
      Enum.reduce(1..30, body, fn _, body ->
        {next, _} = State.prepare(body, input)
        next
      end)

    {vx, vy, vz} = body.velocity
    assert_in_delta :math.sqrt(vx * vx + vy * vy + vz * vz), body.profile.fly_speed, 1.0e-9
    assert vy > 0

    assert {:ok, %{"player" => descending}} =
             Step.advance(
               [
                 {"player", %{body | velocity: {0.0, 0.0, 0.0}},
                  %{Input.idle() | sneaking: true, crawling: true, rolling: true, climbing: true}}
               ],
               &collision_floor/1
             )

    assert descending.mode == :fly
    assert descending.posture == :stand
    assert descending.action == nil
    assert elem(descending.velocity, 1) < 0
  end

  test "landing restores walking once without replaying the consumed gesture" do
    {body, _} =
      State.prepare(
        State.new(Map.put(Profile.default(), :fly_enabled, true), {0.5, 1.0, 0.5}),
        Map.put(Input.idle(), :flight_request, 1)
      )

    landed =
      State.finish(
        %{body | velocity: {12.0, -12.0, 0.0}},
        {{0.5, 0.0, 0.5}, {false, true, false}, false}
      )

    assert landed.mode == :walk
    assert landed.grounded
    assert landed.velocity == {landed.profile.walk_speed, 0.0, 0.0}
    {same, _} = State.prepare(landed, Map.put(Input.idle(), :flight_request, 1))
    assert same.mode == :walk
    {new, _} = State.prepare(landed, Map.put(Input.idle(), :flight_request, 2))
    assert new.mode == :fly
  end

  test "hovering only lands on actual foot support and launch leaves the ground" do
    profile = Map.put(Profile.default(), :fly_enabled, true)
    body = %{State.new(profile, {0.5, 0.0, 0.5}) | mode: :fly}

    assert {:ok, %{"player" => landed}} =
             Step.advance([{"player", body, Input.idle()}], &collision_floor/1)

    assert landed.mode == :walk
    assert landed.grounded
    body = %{body | position: {0.5, 0.03, 0.5}}

    assert {:ok, %{"player" => hovering}} =
             Step.advance([{"player", body, Input.idle()}], &collision_floor/1)

    assert hovering.mode == :fly
    assert hovering.position == body.position
    walking = %{body | position: {0.5, 0.0, 0.5}, grounded: true, mode: :walk}

    assert {:ok, %{"player" => takeoff}} =
             Step.advance(
               [{"player", walking, Map.put(Input.idle(), :flight_request, 1)}],
               &collision_floor/1
             )

    assert takeoff.mode == :fly
    assert elem(takeoff.position, 1) > 0
  end

  test "walls, ceilings and unavailable terrain do not falsely count as landing" do
    body = %{
      State.new(Profile.default(), {0.5, 20.0, 0.5})
      | mode: :fly,
        velocity: {2.0, 2.0, 0.0}
    }

    hit = State.finish(body, {body.position, {true, true, false}, false})
    assert hit.mode == :fly
    refute hit.grounded
    assert hit.velocity == {0.0, 0.0, 0.0}

    missing =
      State.finish(
        %{body | velocity: {0.0, -2.0, 0.0}},
        {body.position, {false, true, false}, true}
      )

    assert missing.mode == :fly
    assert missing.unavailable
    refute missing.grounded
    assert missing.velocity == {0.0, 0.0, 0.0}
  end

  defp collision_floor(queries) do
    {:ok,
     Enum.map(queries, fn {{x, y, z}, {dx, dy, dz}, _, _} ->
       next_y = y + dy
       {{x + dx, max(0.0, next_y), z + dz}, {false, next_y < 0.0, false}, false}
     end)}
  end
end
