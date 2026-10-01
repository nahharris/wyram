defmodule Wyram.Plugin.ModuleName do
  @moduledoc false

  @segment ~r/^[A-Z][A-Za-z0-9_]*$/

  @spec valid?(term()) :: boolean()
  def valid?(module) when is_atom(module) and module not in [nil, false, true] do
    case module |> Atom.to_string() |> String.split(".") do
      ["Elixir" | segments] when segments != [] ->
        Enum.all?(segments, &Regex.match?(@segment, &1))

      _ ->
        false
    end
  end

  def valid?(_), do: false
end
