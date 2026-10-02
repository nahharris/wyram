[destination, ebin] = System.argv()
project = Mix.Project.config()
artifact_path = Path.join(Mix.Project.app_path(), "priv/wyram/catalog.term")
artifact_bytes = File.read!(artifact_path)
artifact = :erlang.binary_to_term(artifact_bytes)
plugin = artifact.plugin
modules = Enum.sort(plugin.owned_modules)
compile_path = Mix.Project.compile_path()

unless modules != [] and plugin.entry in modules and
         modules == Enum.sort(artifact.interface.modules) do
  Mix.raise("compiled catalog has inconsistent module ownership")
end

Enum.each(modules, fn module_name ->
  beam = Path.join(compile_path, module_name <> ".beam")
  bytes = File.read!(beam)
  {:ok, {module, _chunks}} = :beam_lib.chunks(bytes, [:attributes])
  expected_hash = Map.fetch!(artifact.interface.module_hashes, module_name)
  actual_hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  unless Atom.to_string(module) == module_name and expected_hash == actual_hash do
    Mix.raise("stale or mismatched compiled module: #{module_name}")
  end

  File.cp!(beam, Path.join(ebin, module_name <> ".beam"))
end)

File.cp!(artifact_path, Path.join(Path.dirname(destination), "catalog.term"))
version = Keyword.fetch!(project, :version)
%Version{} = Version.parse!(version)
%Version{major: major, minor: minor} = Version.parse!(System.version())

manifest = %{
  id: plugin.id,
  version: version,
  otp: System.otp_release(),
  elixir: "#{major}.#{minor}",
  entry: plugin.entry,
  modules: modules,
  dependencies: plugin.dependencies,
  catalog: "catalog.term",
  catalog_sha256: Base.encode16(:crypto.hash(:sha256, artifact_bytes), case: :lower)
}

File.write!(destination, :json.encode(manifest))
