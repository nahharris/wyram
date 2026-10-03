defmodule Wyram.Plugin.Kind do
  @moduledoc "Supported content kinds and their generated declaration namespaces."
  alias Wyram.Plugin.DSL.Entry

  @namespaces %{
    block: "Blocks",
    biome: "Biomes",
    shaping: "Shaping",
    profile: "Profiles",
    model: "Models",
    character: "Characters",
    worldgen: "WorldGen"
  }

  def kinds, do: Map.keys(@namespaces)
  def namespace(kind), do: Map.fetch!(@namespaces, kind)

  def validate!(kind, env) do
    if kind in kinds(),
      do: kind,
      else: Entry.error!(env, "unsupported catalog kind #{inspect(kind)}")
  end
end
