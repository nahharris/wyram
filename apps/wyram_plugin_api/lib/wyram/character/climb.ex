defmodule Wyram.Character.Climb do
  @moduledoc "Deliberate, supported ledge traversal with a swept rise then crossing."
  alias Wyram.Character.State

  def choose(entries, collision) do
    with {:ok, entries} <- maintain(entries, collision),
         candidates = candidates(entries),
         {:ok, candidates} <- resolve(candidates, :up, collision, &clear?/1),
         {:ok, candidates} <- resolve(candidates, :across, collision, &clear?/1),
         {:ok, candidates} <- resolve(candidates, :support, collision, &supported?/1) do
      plans = Enum.reduce(candidates, %{}, fn c, acc -> Map.put_new(acc, c.id, c.target) end)

      {:ok,
       Enum.map(entries, fn {id, body, input} ->
         action =
           case Map.fetch(plans, id) do
             {:ok, target} -> %{kind: :climb, phase: :rise, target: target}
             :error -> body.action
           end

         {id, %{body | action: action, climb_held: input.climbing}, input}
       end)}
    end
  end

  defp maintain(entries, collision) do
    entries =
      Enum.map(entries, fn {id, body, input} ->
        action = keep_action(body, input)
        {id, %{body | action: action}, input}
      end)

    active = Enum.filter(entries, fn {_, body, _} -> match?(%{kind: :climb}, body.action) end)

    queries =
      Enum.map(active, fn {_, b, _} ->
        {b.action.target, {0.0, -0.05, 0.0}, b.radius, b.height}
      end)

    with {:ok, results} <- query(collision, queries) do
      supported =
        Enum.zip(active, results)
        |> Map.new(fn {{id, _, _}, result} -> {id, supported?(result)} end)

      {:ok,
       Enum.map(entries, fn {id, body, input} ->
         body = if Map.get(supported, id, true), do: body, else: %{body | action: nil}
         {id, body, input}
       end)}
    end
  end

  defp candidates(entries) do
    entries
    |> Enum.filter(&eligible?/1)
    |> Enum.flat_map(fn {id, body, input} ->
      Enum.map(1..body.profile.climb_height, &candidate(id, body, input, &1))
    end)
  end

  defp eligible?({_, b, i}),
    do:
      b.action == nil and b.grounded and b.posture == :stand and i.climbing and not b.climb_held and
        b.profile.climb_height > 0 and (i.forward != 0 or i.right != 0)

  defp candidate(id, body, input, rise) do
    {x, y, z} = body.position
    {dx, dz} = direction(input)
    lifted = {x, y + rise, z}
    target = {x + dx, y + rise, z + dz}

    %{
      id: id,
      target: target,
      up: {body.position, {0.0, rise / 1, 0.0}, body.radius, body.height},
      across: {lifted, {dx, 0.0, dz}, body.radius, body.height},
      support: {target, {0.0, -0.05, 0.0}, body.radius, body.height}
    }
  end

  defp direction(input) do
    x = :math.sin(input.yaw) * input.forward + :math.cos(input.yaw) * input.right
    z = -:math.cos(input.yaw) * input.forward + :math.sin(input.yaw) * input.right
    if abs(x) >= abs(z), do: {sign(x), 0.0}, else: {0.0, sign(z)}
  end

  defp sign(value), do: if(value < 0, do: -1.0, else: 1.0)

  defp resolve(candidates, field, collision, acceptable) do
    with {:ok, results} <- query(collision, Enum.map(candidates, &Map.fetch!(&1, field))) do
      {:ok,
       Enum.zip(candidates, results)
       |> Enum.filter(fn {_, result} -> acceptable.(result) end)
       |> Enum.map(&elem(&1, 0))}
    end
  end

  defp query(_, []), do: {:ok, []}
  defp query(collision, queries), do: collision.(queries)
  defp clear?({_, {false, false, false}, false}), do: true
  defp clear?(_), do: false
  defp supported?({_, {false, true, false}, false}), do: true
  defp supported?(_), do: false

  def prepare(%{action: nil} = body, input), do: State.prepare(body, input)

  def prepare(body, input) do
    {_, y, _} = body.position
    {_, goal_y, _} = body.action.target
    phase = if abs(goal_y - y) < 1.0e-8, do: :cross, else: :rise
    action = %{body.action | phase: phase}
    delta = displacement(body, phase)
    dt = State.tick_ms() / 1000
    {dx, dy, dz} = delta

    next = %{
      body
      | action: action,
        velocity: {dx / dt, dy / dt, dz / dt},
        mode: :climb,
        yaw: input.yaw,
        pitch: input.pitch,
        input_sequence: input.sequence,
        jump_held: input.jump
    }

    {next, {body.position, delta, body.radius, body.height}}
  end

  defp displacement(body, :rise) do
    {_, y, _} = body.position
    {_, goal_y, _} = body.action.target
    {0.0, min(goal_y - y, body.profile.climb_speed * State.tick_ms() / 1000), 0.0}
  end

  defp displacement(body, :cross) do
    {x, _, z} = body.position
    {goal_x, _, goal_z} = body.action.target
    distance = body.profile.climb_speed * State.tick_ms() / 1000
    {clamp(goal_x - x, distance), -0.004, clamp(goal_z - z, distance)}
  end

  defp clamp(value, limit), do: max(-limit, min(limit, value))

  def finish(%{action: nil} = body, result), do: State.finish(body, result)

  def finish(body, {position, {hit_x, hit_y, hit_z}, unavailable} = result) do
    next = State.finish(body, result)

    blocked =
      case body.action.phase do
        :rise -> hit_y
        :cross -> hit_x or hit_z
      end

    done = reached?(position, body.action.target) and next.grounded
    if blocked or unavailable or done, do: %{next | action: nil}, else: next
  end

  defp reached?({x, y, z}, {a, b, c}),
    do: abs(x - a) < 1.0e-8 and abs(y - b) < 1.0e-8 and abs(z - c) < 1.0e-8

  defp keep_action(%{action: %{kind: :climb}} = body, input) do
    if input.climbing and body.posture == :stand, do: body.action, else: nil
  end

  defp keep_action(body, _), do: body.action
end
