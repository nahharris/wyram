ExUnit.start()

defmodule Wyram.PluginTestProject do
  def project, do: Process.get(:wyram_test_project)

  def with_app(app, entry, fun) do
    Process.put(:wyram_test_project, app: app, version: "0.1.0", wyram_plugin: entry, deps: [])
    Mix.Project.push(__MODULE__)

    try do
      fun.()
    after
      Mix.Project.pop()
      Process.delete(:wyram_test_project)
    end
  end
end
