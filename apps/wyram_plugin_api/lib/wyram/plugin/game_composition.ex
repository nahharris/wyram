defmodule Wyram.Plugin.GameComposition do
  @moduledoc false
  alias Wyram.Game.Config
  alias Wyram.Plugin.{ContentCompiler, Diagnostic}

  def compile(plugin, catalog, dependencies) do
    composition = plugin.game.__wyram_game__()

    unless composition.plugin == plugin.entry,
      do:
        throw(
          {:content_error,
           Diagnostic.new!(
             :game_ownership_mismatch,
             "game composition belongs to another plugin",
             composition.source
           )}
        )

    index = ContentCompiler.index(catalog, dependencies)
    entries = Enum.reject(composition.entries, &(&1.kind == :spawn)) |> Map.new(&{&1.kind, &1})
    player = selected(entries, :player, :character, plugin, index)
    spawns = Enum.filter(composition.entries, &(&1.kind == :spawn))

    characters = [
      %{player.data | id: "player"} | Enum.map(spawns, &instantiate_spawn(&1, plugin, index))
    ]

    models = characters |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.map(&model(&1, index))
    terrain = terrain(Map.fetch!(entries, :terrain), plugin, index)

    worldgen =
      if Map.has_key?(entries, :worldgen),
        do: selected(entries, :worldgen, :worldgen, plugin, index).data

    {:ok,
     Config.new!(%{
       terrain: terrain,
       profile: player.data.profile,
       models: models,
       characters: characters,
       worldgen: worldgen,
       spawn: Map.get(entries, :spawn_policy, %{value: :configured}).value
     })}
  rescue
    error ->
      {:error, Diagnostic.new!(:invalid_game_config, Exception.message(error), source(plugin))}
  catch
    {:content_error, diagnostic} -> {:error, diagnostic}
  end

  defp selected(entries, key, kind, plugin, index) do
    entry = Map.fetch!(entries, key)
    ContentCompiler.select(entry.value, kind, plugin, index, entry.source)
  end

  defp terrain(entry, plugin, index) do
    Map.new(entry.value, fn {key, {:__wyram_module__, module}} ->
      {key, ContentCompiler.select(module, :block, plugin, index, entry.source).data}
    end)
  end

  defp instantiate_spawn(entry, plugin, index) do
    {module, options} = entry.value

    if not Keyword.keyword?(options) or
         Keyword.keys(options) -- [:id, :position, :yaw, :pitch] != [],
       do: raise(ArgumentError, "spawn accepts only :id, :position, :yaw, and :pitch")

    character = ContentCompiler.select(module, :character, plugin, index, entry.source).data
    struct!(character, options)
  end

  defp model(id, index) do
    index |> Map.values() |> Enum.find(&(&1.kind == :model and &1.id == id)) |> Map.fetch!(:data)
  end

  defp source(plugin),
    do: %Wyram.Plugin.SourceLocation{file: "mix.exs", line: 1, module: plugin.entry}
end
