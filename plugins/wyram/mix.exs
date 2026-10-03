defmodule Wyram.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:wyram_prepare] ++ Mix.compilers() ++ [:wyram],
      wyram_plugin: Wyram,
      deps: [{:wyram_plugin_api, path: "../../apps/wyram_plugin_api"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
