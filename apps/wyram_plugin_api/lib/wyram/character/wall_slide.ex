defmodule Wyram.Character.WallSlide do
  @moduledoc "Deliberate descending contact, recomputed against packed terrain every step."
  alias Wyram.Character.State

  def choose(entries, collision) do
    entries = Enum.map(entries, fn {id, body, input} -> {id, clear_previous(body), input} end)
    candidates = Enum.filter(entries, &eligible?/1)

    queries =
      Enum.map(candidates, fn {_, body, input} ->
        {_, {position, {dx, _, dz}, radius, height}} = State.prepare(body, input)
        {position, {dx, 0.0, dz}, radius, height}
      end)

    with {:ok, results} <- query(collision, queries) do
      contacts =
        Enum.zip(candidates, results)
        |> Map.new(fn {{id, _, _}, result} -> {id, contact?(result)} end)

      {:ok,
       Enum.map(entries, fn {id, body, input} ->
         body =
           if Map.get(contacts, id, false),
             do: %{body | action: %{kind: :wall_slide, phase: :active}},
             else: body

         {id, body, input}
       end)}
    end
  end

  defp clear_previous(%{action: %{kind: :wall_slide}} = body), do: %{body | action: nil}
  defp clear_previous(body), do: body

  defp eligible?({_, b, i}),
    do:
      b.action == nil and not b.grounded and b.profile.wall_slide_enabled and
        elem(b.velocity, 1) <= 0 and deliberate?(i)

  defp deliberate?(i),
    do:
      i.sneaking and not i.crawling and not i.climbing and not i.jump and
        (i.forward != 0 or i.right != 0)

  defp query(_, []), do: {:ok, []}
  defp query(collision, queries), do: collision.(queries)
  defp contact?({_, {hit_x, _, hit_z}, false}), do: hit_x or hit_z
  defp contact?(_), do: false

  def prepare(body, input) do
    {next, {position, {dx, _, dz}, radius, height}} = State.prepare(body, input)
    {vx, vy, vz} = next.velocity
    vy = max(vy, -body.profile.wall_slide_speed)
    next = %{next | velocity: {vx, vy, vz}, mode: :wall_slide}
    {next, {position, {dx, vy * State.tick_ms() / 1000, dz}, radius, height}}
  end

  def finish(body, {_, {hit_x, _, hit_z}, unavailable} = result) do
    next = State.finish(body, result)

    if next.grounded or unavailable or not (hit_x or hit_z),
      do: %{next | action: nil, mode: :sneak},
      else: next
  end
end
