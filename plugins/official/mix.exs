defmodule WyramMods.Official.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_official,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:wyram_plugin_api, path: "../../apps/wyram_plugin_api"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
