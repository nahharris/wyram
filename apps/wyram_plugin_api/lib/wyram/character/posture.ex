defmodule Wyram.Character.Posture do
  @moduledoc "Feet-anchored posture transitions, with full-body clearance before expansion."

  def request(body, input) do
    posture = requested(body, input)
    {height, eye} = dimensions(body.profile, posture)
    wanted = %{body | posture: posture, height: height, eye_height: eye}
    query = {body.position, {0.0, 0.0, 0.0}, body.radius, height}
    {wanted, query}
  end

  def approve(body, wanted, result) do
    if wanted.height <= body.height or clear?(result), do: wanted, else: body
  end

  defp clear?({_, {false, false, false}, false}), do: true
  defp clear?(_), do: false
  defp dimensions(p, :stand), do: {p.standing_height, p.standing_eye}
  defp dimensions(p, :crouch), do: {p.crouch_height, p.crouch_eye}
  defp dimensions(p, :prone), do: {p.prone_height, p.prone_eye}

  def protect_edge(original, prepared, result, support) do
    case support do
      {_, {_, true, _}, false} -> result
      {_, _, true} -> {original.position, {false, false, false}, true}
      _ -> stop_horizontal(original, prepared, result)
    end
  end

  def edge_guard?(body, prepared),
    do: body.grounded and body.posture in [:crouch, :prone] and elem(prepared.velocity, 1) <= 0

  def support_query(body, {position, _, _}),
    do: {position, {0.0, -0.05, 0.0}, body.radius, body.height}

  defp stop_horizontal(original, _prepared, {_, _, unavailable}) do
    {original.position, {true, true, true}, unavailable}
  end

  defp requested(%{action: %{kind: :roll}}, _), do: :prone
  defp requested(_, %{crawling: true}), do: :prone
  defp requested(_, %{sneaking: true}), do: :crouch
  defp requested(_, _), do: :stand
end
