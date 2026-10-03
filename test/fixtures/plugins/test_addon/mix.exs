defmodule TestAddon.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_addon,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:wyram_prepare] ++ Mix.compilers() ++ [:wyram],
      wyram_plugin: [entry: TestAddon],
      deps: [
        {:wyram_plugin_api, path: "../../../../apps/wyram_plugin_api"},
        {:test_terrain, path: "../test_terrain"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
