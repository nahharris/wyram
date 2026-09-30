defmodule Wyram.Character.StateTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Input, Profile, State}

  test "only bounded sequenced intent is accepted" do
    assert {:ok, input} =
             Input.decode(%{
               "sequence" => 3,
               "epoch" => 0,
               "forward" => 1,
               "right" => 1,
               "yaw" => 0.0,
               "pitch" => 0.0,
               "jump" => false,
               "running" => true
             })

    assert input.sequence == 3
    assert Input.decode(%{"sequence" => -1}) == {:error, :invalid_input}

    assert Input.decode(%{
             "sequence" => 3,
             "epoch" => 0,
             "forward" => 10,
             "right" => 0,
             "yaw" => 0.0,
             "pitch" => 0.0,
             "jump" => false,
             "running" => false
           }) == {:error, :invalid_input}
  end

  test "Elixir normalizes diagonal intent and owns the fixed timestep" do
    state = State.new(Profile.default(), {0.5, 0.0, 0.5})
    input = Map.merge(Input.idle(), %{forward: 1.0, right: 1.0, running: true})
    {next, {_position, {dx, _dy, dz}, _radius, _height}} = State.prepare(state, input)
    assert_in_delta :math.sqrt(dx * dx + dz * dz), 9.0 * 0.02, 1.0e-10
    assert next.mode == :run
  end

  test "jump is edge-triggered only while grounded and ceiling hits cancel ascent" do
    state = %{State.new(Profile.default(), {0.5, 0.0, 0.5}) | grounded: true}
    input = %{Input.idle() | jump: true}
    {jumping, request} = State.prepare(state, input)
    assert jumping.velocity |> elem(1) > 0
    assert elem(request, 1) |> elem(1) > 0
    hit = State.finish(jumping, {{0.5, 0.1, 0.5}, {false, true, false}, false})
    assert elem(hit.velocity, 1) == 0.0
    {held, _} = State.prepare(%{hit | grounded: true}, input)
    assert elem(held.velocity, 1) < 0
  end

  test "unavailable terrain freezes the body and is explicitly reported" do
    state = State.new(Profile.default(), {0.5, 0.0, 0.5})
    {prepared, _} = State.prepare(state, %{Input.idle() | forward: 1.0})
    frozen = State.finish(prepared, {state.position, {false, false, false}, true})
    assert frozen.position == state.position
    assert frozen.velocity == {0.0, 0.0, 0.0}
    assert frozen.unavailable
  end
end
