defmodule WyramMods.TestAddon.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_test_addon,
      version: "0.1.0",
      elixir: "~> 1.20",
      wyram_plugin: [id: "test_addon", entry: WyramMods.TestAddon, dependencies: ["test_terrain"]],
      deps: [{:wyram_plugin_api, path: "../../../../apps/wyram_plugin_api"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
