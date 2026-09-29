[destination, ebin] = System.argv()
project = Mix.Project.config()
plugin = Keyword.fetch!(project, :wyram_plugin)
id = Keyword.fetch!(plugin, :id)
entry = plugin |> Keyword.fetch!(:entry) |> Atom.to_string()
dependencies = Keyword.fetch!(plugin, :dependencies)

beams =
  Mix.Project.compile_path()
  |> Path.join("Elixir.WyramMods.*.beam")
  |> String.replace("\\", "/")
  |> Path.wildcard()
  |> Enum.sort()

modules = Enum.map(beams, &Path.basename(&1, ".beam"))

unless is_binary(id) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) and
         is_list(dependencies) and Enum.all?(dependencies, &is_binary/1) and
         entry in modules do
  Mix.raise(
    "invalid Wyram plugin declaration or missing compiled entry module: #{inspect({id, entry, dependencies, modules})}"
  )
end

Enum.each(beams, &File.cp!(&1, Path.join(ebin, Path.basename(&1))))

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
