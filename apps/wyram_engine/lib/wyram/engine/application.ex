defmodule Wyram.Engine.Application do
  @moduledoc false
  use Application
  alias Wyram.Engine.{ClientPort, Paths, PluginManager, World}

  @impl true
  def start(_type, _args) do
    data_dir = Paths.data_dir()
    File.mkdir_p!(Path.join(data_dir, "plugins"))
    File.mkdir_p!(Path.join(data_dir, "worlds"))

    children = [
      {PluginManager, directory: Path.join(data_dir, "plugins")},
      {Registry, keys: :unique, name: Wyram.Engine.RegionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Wyram.Engine.RegionSupervisor},
      {World, directory: Path.join(data_dir, "worlds")},
      ClientPort
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Wyram.Engine.Supervisor)
  end
end
