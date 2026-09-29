defmodule WyramMods.Wyram.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_game,
      version: "0.1.0",
      elixir: "~> 1.20",
      wyram_plugin: [id: "wyram", entry: WyramMods.Wyram, dependencies: []],
      deps: [{:wyram_plugin_api, path: "../../apps/wyram_plugin_api"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
