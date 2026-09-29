defmodule Wyram.PluginApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_plugin_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
