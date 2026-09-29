defmodule Wyram.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        wyram: [
          applications: [wyram_engine: :permanent, wyram_plugin_api: :permanent],
          include_executables_for: [:windows]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.2", only: :test}
    ]
  end
end
