defmodule Wyram.Game do
  @moduledoc "Declarative startup composition selecting registered content for a playable game."
  alias Wyram.Plugin.Catalog
  alias Wyram.Plugin.DSL.{Entry, Literal}

  defmacro __using__(options) do
    env = __CALLER__
    options = Entry.keyword_options!(options, env, "game")

    if options != [], do: Entry.error!(env, "game takes no metadata options")

    plugin = Entry.plugin!(env)
    Module.put_attribute(env.module, :wyram_game_plugin, plugin)
    Module.register_attribute(env.module, :wyram_game_entries, accumulate: true)

    quote do
      import Kernel, except: [spawn: 1, spawn: 2]

      import Wyram.Game,
        only: [
          palette: 1,
          worldgen: 1,
          scenery: 1,
          player: 1,
          spawn: 1,
          spawn: 2,
          spawn_policy: 1
        ]

      @before_compile Wyram.Game
    end
  end

  defmacro palette(fields), do: put(:palette, Literal.normalize!(fields, __CALLER__), __CALLER__)

  defmacro worldgen(module),
    do: put(:worldgen, Entry.module!(module, __CALLER__, "worldgen"), __CALLER__)

  defmacro scenery(options) do
    env = __CALLER__
    options = Entry.keyword_options!(options, env, "scenery")
    put(:scenery, Literal.normalize!(options, env), env)
  end

  defmacro player(module),
    do: put(:player, Entry.module!(module, __CALLER__, "player"), __CALLER__)

  defmacro spawn_policy(policy) do
    unless policy in [:surface, :configured], do: Entry.error!(__CALLER__, "invalid spawn policy")
    put(:spawn_policy, policy, __CALLER__)
  end

  defmacro spawn(module, options \\ []) do
    module = Entry.module!(module, __CALLER__, "spawn character")
    put(:spawn, {module, Literal.normalize!(options, __CALLER__)}, __CALLER__)
  end

  defmacro __before_compile__(env) do
    data = %{
      plugin: Module.get_attribute(env.module, :wyram_game_plugin),
      entries: env.module |> Module.get_attribute(:wyram_game_entries) |> Enum.reverse(),
      source: Catalog.source(env)
    }

    quote do
      @doc false
      def __wyram_game__, do: unquote(Macro.escape(data))
    end
  end

  defp put(kind, value, env) do
    entries = Module.get_attribute(env.module, :wyram_game_entries)

    if kind != :spawn and Enum.any?(entries, &(&1.kind == kind)),
      do: Entry.error!(env, "#{kind} may be declared only once")

    Module.put_attribute(env.module, :wyram_game_entries, %{
      kind: kind,
      value: value,
      source: Catalog.source(env)
    })

    quote do: :ok
  end
end
