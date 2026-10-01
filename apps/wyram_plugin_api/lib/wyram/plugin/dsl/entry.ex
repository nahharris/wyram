defmodule Wyram.Plugin.DSL.Entry do
  @moduledoc false

  alias Wyram.Block.Ref

  @keys [:id, :dependencies, :declarations, :providers, :game]

  def options!(options, env) do
    options = keyword_options!(options, env, "plugin")
    reject_unknown!(options, @keys, env, "plugin")

    id = fetch_id!(options, env)
    dependencies = literal_list!(options, :dependencies, [], env)

    unless Enum.all?(dependencies, &Ref.valid_plugin_id?/1) do
      error!(env, "dependencies must be a literal list of valid plugin IDs")
    end

    if length(dependencies) != length(Enum.uniq(dependencies)) do
      error!(env, "dependencies cannot contain duplicates")
    end

    if id in dependencies, do: error!(env, "a plugin cannot depend on itself")

    %{
      id: id,
      dependencies: dependencies,
      declaration_modules:
        [env.module | module_list!(options, :declarations, env)] |> Enum.uniq(),
      providers: module_list!(options, :providers, env),
      game: module_option!(options, :game, env)
    }
  end

  def keyword_options!(options, env, label) when is_list(options) do
    if Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) do
      options
    else
      error!(env, "#{label} options must be a unique literal keyword list")
    end
  end

  def keyword_options!(_options, env, label),
    do: error!(env, "#{label} options must be a literal keyword list")

  def module!(ast, env, label) do
    case ast do
      {:__aliases__, _, [_ | _]} ->
        case Macro.expand(ast, env) do
          module when is_atom(module) and module not in [nil, true, false] -> module
          _ -> error!(env, "#{label} must be a literal module alias")
        end

      _ ->
        error!(env, "#{label} must be a literal module alias")
    end
  end

  def error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end

  defp fetch_id!(options, env) do
    case Keyword.fetch(options, :id) do
      {:ok, id} when is_binary(id) ->
        if Ref.valid_plugin_id?(id), do: id, else: error!(env, "plugin id is invalid")

      {:ok, _} ->
        error!(env, "plugin id must be a literal string")

      :error ->
        error!(env, "missing required plugin id option")
    end
  end

  defp reject_unknown!(options, allowed, env, label) do
    case Keyword.keys(options) -- allowed do
      [] ->
        :ok

      unknown ->
        error!(env, "unknown #{label} option(s): #{Enum.map_join(unknown, ", ", &inspect/1)}")
    end
  end

  defp literal_list!(options, key, default, env) do
    case Keyword.get(options, key, default) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: values,
          else: error!(env, "#{key} must be a literal list of strings")

      _ ->
        error!(env, "#{key} must be a literal list of strings")
    end
  end

  defp module_list!(options, key, env) do
    case Keyword.get(options, key, []) do
      values when is_list(values) ->
        modules = Enum.map(values, &module!(&1, env, "#{key} entries"))

        if length(modules) == length(Enum.uniq(modules)) do
          modules
        else
          error!(env, "#{key} cannot contain duplicate modules")
        end

      _ ->
        error!(env, "#{key} must be a literal list of module aliases")
    end
  end

  defp module_option!(options, key, env) do
    case Keyword.get(options, key) do
      nil -> nil
      ast -> module!(ast, env, key)
    end
  end
end
