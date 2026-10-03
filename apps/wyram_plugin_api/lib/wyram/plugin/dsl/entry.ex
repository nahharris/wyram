defmodule Wyram.Plugin.DSL.Entry do
  @moduledoc false

  alias Wyram.Block.Ref
  alias Wyram.Plugin.ModuleName

  def options!(options, env) do
    options = keyword_options!(options, env, "plugin")
    reject_unknown!(options, [], env, "plugin")

    unless plugin!(env) == env.module,
      do: error!(env, "use Wyram.Plugin belongs in the configured Mix entrypoint")

    app = Mix.Project.config()[:app]

    unless is_atom(app) and app not in [nil, true, false] and
             Ref.valid_plugin_id?(Atom.to_string(app)) do
      error!(env, "Wyram plugins require a valid :app in mix.exs")
    end

    %{
      id: Atom.to_string(app),
      dependencies: [],
      declaration_modules: [env.module],
      catalogs: [],
      providers: [],
      game: nil
    }
  end

  def project_entry do
    case Mix.Project.config()[:wyram_plugin] do
      nil ->
        :none

      entry ->
        if ModuleName.valid?(entry),
          do: {:ok, entry},
          else: {:error, ":wyram_plugin must be a module alias"}
    end
  end

  def plugin!(env) do
    case project_entry() do
      {:ok, entry} -> entry
      _ -> error!(env, "declare the plugin entry module with wyram_plugin: Module in mix.exs")
    end
  end

  def local_id!(symbol, options, env) do
    id =
      Keyword.get_lazy(options, :id, fn -> symbol |> Atom.to_string() |> Macro.underscore() end)

    unless Ref.valid_local_id?(id), do: error!(env, "id must be a valid literal local ID string")
    id
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

  defp reject_unknown!(options, allowed, env, label) do
    case Keyword.keys(options) -- allowed do
      [] ->
        :ok

      unknown ->
        error!(env, "unknown #{label} option(s): #{Enum.map_join(unknown, ", ", &inspect/1)}")
    end
  end
end
