defmodule WyramMods.Example.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_example,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:wyram_prepare] ++ Mix.compilers() ++ [:wyram],
      wyram_plugin: [entry: WyramMods.Example],
      deps: [
        {:wyram_plugin_api, path: "../../apps/wyram_plugin_api"},
        {:wyram_game, path: "../wyram"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
