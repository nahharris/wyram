defmodule Wyram.Plugin.DSL.Literal do
  @moduledoc false

  alias Wyram.Plugin.DSL.{Entry, StructLiteral}

  def normalize!(ast, env, label \\ "capability configuration") do
    case normalize(ast, env) do
      {:ok, value} -> value
      :error -> Entry.error!(env, "#{label} must contain only literal values and named structs")
    end
  end

  defp normalize(ast, _env) when is_atom(ast) or is_binary(ast) or is_number(ast), do: {:ok, ast}
  defp normalize(nil, _env), do: {:ok, nil}

  defp normalize({:-, _meta, [number]}, _env) when is_number(number), do: {:ok, -number}

  defp normalize({:__aliases__, _, [_ | _]} = alias_ast, env) do
    case Entry.module!(alias_ast, env, "module alias") do
      module -> {:ok, {:__wyram_module__, module}}
    end
  end

  defp normalize({{:., _, [module_ast, function]}, _, args}, env)
       when function in [:pixels, :blocks] and is_list(args) do
    with Wyram.Units <- Macro.expand(module_ast, env),
         {:ok, values} <- reduce_list(args, env, []),
         true <- Enum.all?(values, &is_number/1),
         true <- {function, length(values)} in [pixels: 1, blocks: 1, blocks: 2] do
      {:ok, apply(Wyram.Units, function, values)}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp normalize({:%, meta, [module_ast, {:%{}, _map_meta, fields}]}, env)
       when is_list(fields) do
    module = Entry.module!(module_ast, line_env(env, meta), "struct name")

    with {:ok, normalized_fields} <- normalize_fields(fields, env),
         do: {:ok, %StructLiteral{module: module, fields: normalized_fields}}
  end

  defp normalize({:%{}, _meta, fields}, env) when is_list(fields) do
    normalize_fields(fields, env)
  end

  defp normalize({:{}, _meta, elements}, env) when is_list(elements) do
    case reduce_list(elements, env, []) do
      {:ok, values} -> {:ok, List.to_tuple(values)}
      :error -> :error
    end
  end

  defp normalize({:-, _meta, _args}, _env), do: :error

  defp normalize(ast, env) when is_list(ast) do
    reduce_list(ast, env, [])
  end

  defp normalize(ast, env) when is_tuple(ast) do
    if ast_call?(ast), do: :error, else: normalize_tuple(ast, env)
  end

  defp normalize(_ast, _env), do: :error

  defp normalize_fields(fields, env) do
    Enum.reduce_while(fields, {:ok, %{}}, fn
      {key_ast, value_ast}, {:ok, acc} ->
        with {:ok, key} <- normalize(key_ast, env),
             true <- is_atom(key) || is_binary(key) || is_number(key),
             false <- Map.has_key?(acc, key),
             {:ok, value} <- normalize(value_ast, env) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp reduce_list([], _env, acc), do: {:ok, Enum.reverse(acc)}

  defp reduce_list([head | tail], env, acc) do
    case normalize(head, env) do
      {:ok, value} -> reduce_list(tail, env, [value | acc])
      :error -> :error
    end
  end

  defp normalize_tuple(tuple, env) do
    tuple
    |> Tuple.to_list()
    |> reduce_list(env, [])
    |> case do
      {:ok, values} -> {:ok, List.to_tuple(values)}
      :error -> :error
    end
  end

  defp ast_call?({name, metadata, args})
       when is_atom(name) and is_list(metadata) and (is_list(args) or is_nil(args)),
       do: true

  defp ast_call?({{:., _, _}, _, _}), do: true
  defp ast_call?(_), do: false

  defp line_env(env, metadata) do
    case Keyword.fetch(metadata, :line) do
      {:ok, line} -> %{env | line: line}
      :error -> env
    end
  end
end
