defmodule CrossPluginBase.MixProject do
  use Mix.Project

  def project do
    api_path =
      System.get_env("WYRAM_PLUGIN_API_PATH") ||
        Path.expand("../../../../../apps/wyram_plugin_api", __DIR__)

    [
      app: :wyram_cross_plugin_base,
      version: "0.1.0",
      build_path: System.get_env("WYRAM_FIXTURE_BUILD_PATH") || "_build",
      deps: [
        {:wyram_plugin_api, path: api_path}
      ],
      compilers: [:wyram_prepare] ++ Mix.compilers() ++ [:wyram],
      wyram_plugin: CrossPluginBase.Plugin
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
