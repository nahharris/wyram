defmodule Wyram.Plugin.Kind do
  @moduledoc "Supported content kinds and their catalog names."
  alias Wyram.Plugin.DSL.Entry

  @catalogs %{
    blocks: :block,
    biomes: :biome,
    terrains: :terrain,
    profiles: :profile,
    models: :model,
    characters: :character,
    worldgen: :worldgen
  }
  @namespaces %{
    block: "Blocks",
    biome: "Biomes",
    terrain: "Terrains",
    profile: "Profiles",
    model: "Models",
    character: "Characters",
    worldgen: "WorldGen"
  }

  def kinds, do: Map.values(@catalogs)
  def namespace(kind), do: Map.fetch!(@namespaces, kind)

  def catalog_kind!(name, env) do
    case Map.fetch(@catalogs, name) do
      {:ok, kind} ->
        kind

      :error ->
        Entry.error!(
          env,
          "unknown catalog #{inspect(name)}; expected #{inspect(Map.keys(@catalogs))}"
        )
    end
  end

  def validate!(kind, env) do
    if kind in kinds(),
      do: kind,
      else: Entry.error!(env, "unsupported catalog kind #{inspect(kind)}")
  end
end
