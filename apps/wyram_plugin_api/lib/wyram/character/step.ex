defmodule Wyram.Character.Step do
  @moduledoc "Reusable batched simulation phases; owners inject packed collision queries."
  alias Wyram.Character.{Climb, Posture}

  def advance(entries, collision) do
    with {:ok, entries} <- postures(entries, collision),
         {:ok, entries} <- Climb.choose(entries, collision),
         prepared =
           Enum.map(entries, fn {id, body, input} ->
             {next, query} = Climb.prepare(body, input)
             {id, body, next, query}
           end),
         {:ok, results} <- collision.(Enum.map(prepared, &elem(&1, 3))),
         {:ok, results} <- edges(prepared, results, collision) do
      {:ok,
       Enum.zip(prepared, results)
       |> Map.new(fn {{id, _, body, _}, result} -> {id, Climb.finish(body, result)} end)}
    end
  end

  defp postures(entries, collision) do
    requests =
      Enum.map(entries, fn {id, body, input} ->
        {wanted, query} = Posture.request(body, input)
        {id, body, wanted, input, query}
      end)

    expanding =
      Enum.filter(requests, fn {_, body, wanted, _, _} -> wanted.height > body.height end)

    with {:ok, results} <- query(collision, Enum.map(expanding, &elem(&1, 4))) do
      approvals =
        Enum.zip(expanding, results) |> Map.new(fn {{id, _, _, _, _}, result} -> {id, result} end)

      {:ok,
       Enum.map(requests, fn {id, body, wanted, input, _} ->
         result = Map.get(approvals, id, {body.position, {false, false, false}, false})
         {id, Posture.approve(body, wanted, result), input}
       end)}
    end
  end

  defp edges(prepared, results, collision) do
    pairs = Enum.zip(prepared, results)

    guarded =
      Enum.filter(pairs, fn {{_, body, next, _}, _} -> Posture.edge_guard?(body, next) end)

    queries =
      Enum.map(guarded, fn {{_, _, next, _}, result} -> Posture.support_query(next, result) end)

    with {:ok, supports} <- query(collision, queries) do
      protected =
        Enum.zip(guarded, supports)
        |> Map.new(fn {{{id, body, next, _}, result}, support} ->
          {id, Posture.protect_edge(body, next, result, support)}
        end)

      {:ok, Enum.map(pairs, fn {{id, _, _, _}, result} -> Map.get(protected, id, result) end)}
    end
  end

  defp query(_collision, []), do: {:ok, []}
  defp query(collision, queries), do: collision.(queries)
end
