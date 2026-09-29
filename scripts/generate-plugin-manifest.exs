[destination, ebin] = System.argv()
project = Mix.Project.config()
plugin = Keyword.fetch!(project, :wyram_plugin)
id = Keyword.fetch!(plugin, :id)
entry = plugin |> Keyword.fetch!(:entry) |> Atom.to_string()
dependencies = Keyword.fetch!(plugin, :dependencies)

modules =
  ebin
  |> Path.join("Elixir.WyramMods.*.beam")
  |> String.replace("\\", "/")
  |> Path.wildcard()
  |> Enum.map(&(&1 |> Path.basename(".beam")))
  |> Enum.sort()

unless is_binary(id) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) and
         is_list(dependencies) and Enum.all?(dependencies, &is_binary/1) and
         entry in modules do
  Mix.raise(
    "invalid Wyram plugin declaration or missing compiled entry module: #{inspect({id, entry, dependencies, modules})}"
  )
end

version = Keyword.fetch!(project, :version)
%Version{} = Version.parse!(version)
%Version{major: major, minor: minor} = Version.parse!(System.version())

manifest = %{
  id: id,
  version: version,
  api: Wyram.PluginApi.version(),
  otp: System.otp_release(),
  elixir: "#{major}.#{minor}",
  entry: entry,
  modules: modules,
  dependencies: dependencies
}

File.write!(destination, :json.encode(manifest))
