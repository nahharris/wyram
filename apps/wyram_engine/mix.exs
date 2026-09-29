defmodule Wyram.Engine.MixProject do
  use Mix.Project

  def project do
    [
      app: :wyram_engine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:wyram_plugin_api, in_umbrella: true}, {:rustler, "~> 0.38"}, {:jason, "~> 1.4"}]
    ]
  end

  def application do
    [mod: {Wyram.Engine.Application, []}, extra_applications: [:logger, :crypto]]
  end
end
