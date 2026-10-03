defmodule Wyram.Engine.PluginManager do
  @moduledoc "Validates compiled plugin catalogs and loads their trusted BEAM modules at startup."
  use GenServer
  import Bitwise

  alias Wyram.Character.Model
  alias Wyram.Engine.PluginCatalog

  @max_package_bytes 16 * 1024 * 1024
  @max_files 128
  @max_beam_atoms 100_000
  @atom_limit_reserve 10_000
  @catalog_schema_modules [
    Wyram.Block.Ref,
    Wyram.Capability.Collision,
    Wyram.Capability.Geometry,
    Wyram.Capability.Material,
    Wyram.Capability.Liquid,
    Wyram.Character.Definition,
    Wyram.Character.Model,
    Wyram.Character.Profile,
    Wyram.Engine.PluginCatalog,
    Wyram.Game.Config,
    Wyram.WorldGen.Config,
    Wyram.WorldGen.Biome,
    Wyram.WorldGen.Field,
    Wyram.WorldGen.Carver,
    Wyram.WorldGen.Feature,
    Wyram.WorldGen.Islands,
    Wyram.WorldGen.Terrain,
    Wyram.Plugin.BlockDefaults,
    Wyram.Plugin.CapabilityContribution,
    Wyram.Plugin.Declaration,
    Wyram.Plugin.Declaration.Template,
    Wyram.Plugin.DSL.Capability,
    Wyram.Plugin.DSL.CollectedDeclaration,
    Wyram.Plugin.DSL.Entry,
    Wyram.Plugin.DSL.Literal,
    Wyram.Plugin.DSL.StructLiteral,
    Wyram.Plugin.Declarations,
    Wyram.Plugin.Diagnostic,
    Wyram.Plugin.ModuleName,
    Wyram.Plugin.Provider,
    Wyram.Plugin.Providers.Collision,
    Wyram.Plugin.Providers.Geometry,
    Wyram.Plugin.Providers.Material,
    Wyram.Plugin.Providers.Liquid,
    Wyram.Plugin.Descriptor,
    Wyram.Plugin.SourceLocation
  ]

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec blocks() :: %{String.t() => pos_integer()}
  def blocks, do: GenServer.call(__MODULE__, :blocks)

  @spec block_colors() :: %{pos_integer() => [integer()]}
  def block_colors, do: GenServer.call(__MODULE__, :block_colors)

  def spawn_policy, do: GenServer.call(__MODULE__, :spawn_policy)
  def worldgen, do: GenServer.call(__MODULE__, :worldgen)
  def liquids, do: GenServer.call(__MODULE__, :liquids)
  def render_descriptors, do: GenServer.call(__MODULE__, :render)
  def noncolliding, do: GenServer.call(__MODULE__, :noncolliding)
  def placeable, do: GenServer.call(__MODULE__, :placeable)

  @spec terrain_palette() :: [pos_integer()]
  def terrain_palette, do: GenServer.call(__MODULE__, :terrain_palette)

  @spec plugin_versions() :: %{String.t() => String.t()}
  def plugin_versions, do: GenServer.call(__MODULE__, :plugin_versions)

  @spec player_profile() :: map()
  def player_profile, do: GenServer.call(__MODULE__, :player_profile)

  def character_definitions, do: GenServer.call(__MODULE__, :character_definitions)
  def character_models, do: GenServer.call(__MODULE__, :character_models)

  @doc false
  def beam_module_name(<<"FOR1", size::unsigned-big-32, "BEAM", chunks::binary>> = beam)
      when size == byte_size(beam) - 8 do
    case find_module_atom(chunks) do
      {:ok, name} -> {:ok, name}
      _ -> {:error, :invalid_beam}
    end
  end

  def beam_module_name(_), do: {:error, :invalid_beam}

  @impl true
  def init(options) do
    directory = Keyword.fetch!(options, :directory)
    game = Keyword.get(options, :game) || System.get_env("WYRAM_GAME_PLUGIN")

    with {:ok, packages} <- scan(directory),
         {:ok, saved_ids} <- saved_block_ids(directory),
         {:ok, registry} <- PluginCatalog.build(packages, game: game, saved_block_ids: saved_ids),
         :ok <- validate_load_collisions(packages),
         :ok <- load_packages(packages, registry.package_order) do
      {:ok, Map.delete(registry, :package_order)}
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    _ -> {:stop, :invalid_plugin_installation}
  end

  @impl true
  def handle_call(:player_profile, _from, state), do: {:reply, state.player_profile, state}

  def handle_call(:character_definitions, _from, state),
    do: {:reply, state.character_definitions, state}

  def handle_call(:character_models, _from, state),
    do: {:reply, Enum.map(state.character_models, &Model.to_wire/1), state}

  def handle_call(:spawn_policy, _from, state), do: {:reply, state.spawn_policy, state}
  def handle_call(:worldgen, _from, state), do: {:reply, state.worldgen, state}
  def handle_call(:blocks, _from, state), do: {:reply, state.blocks, state}
  def handle_call(:liquids, _from, state), do: {:reply, state.liquids, state}
  def handle_call(:render, _from, state), do: {:reply, state.render, state}
  def handle_call(:noncolliding, _from, state), do: {:reply, state.noncolliding, state}
  def handle_call(:placeable, _from, state), do: {:reply, state.placeable, state}
  def handle_call(:block_colors, _from, state), do: {:reply, state.colors, state}
  def handle_call(:terrain_palette, _from, state), do: {:reply, state.palette, state}
  def handle_call(:plugin_versions, _from, state), do: {:reply, state.versions, state}

  defp scan(directory) do
    paths =
      directory
      |> Path.join("*.wyrplug")
      |> String.replace("\\", "/")
      |> Path.wildcard()
      |> Enum.sort()

    with {:ok, packages} <- read_packages_metadata(paths),
         :ok <- validate_atom_budget(Enum.map(packages, & &1.atom_count)),
         :ok <- prepare_beam_atoms(packages),
         :ok <- ensure_catalog_schema_modules(),
         {:ok, packages} <- decode_packages(packages) do
      if packages == [], do: {:error, :no_plugins_installed}, else: {:ok, packages}
    end
  end

  defp read_packages_metadata(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, packages} ->
      case read_package_metadata(path) do
        {:ok, package} -> {:cont, {:ok, [package | packages]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      error -> error
    end
  end

  defp read_package_metadata(path) do
    with {:ok, %{size: size}} when size <= @max_package_bytes <- File.stat(path),
         :ok <- validate_archive(path),
         {:ok, contents} <- :zip.extract(String.to_charlist(path), [:memory]),
         true <- length(contents) <= @max_files,
         true <-
           Enum.reduce(contents, 0, fn {_, bytes}, total -> total + byte_size(bytes) end) <=
             @max_package_bytes,
         :ok <- validate_paths(contents),
         {:ok, manifest_bytes} <- fetch_file(contents, "manifest.json"),
         {:ok, manifest} <- Jason.decode(manifest_bytes),
         :ok <- validate_manifest(manifest),
         {:ok, artifact_bytes} <- fetch_file(contents, "catalog.term"),
         true <- byte_size(artifact_bytes) <= @max_package_bytes,
         true <- sha256(artifact_bytes) == manifest["catalog_sha256"],
         :ok <- verify_beam_identities(manifest, contents),
         {:ok, atom_count} <- total_beam_atom_count(manifest["modules"], contents) do
      {:ok,
       %{
         path: path,
         manifest: manifest,
         catalog_bytes: artifact_bytes,
         contents: contents,
         atom_count: atom_count
       }}
    else
      false -> {:error, {:invalid_plugin_package, path}}
      {:error, reason} -> {:error, {:invalid_plugin_package, path, reason}}
      _ -> {:error, {:invalid_plugin_package, path}}
    end
  end

  defp decode_packages(packages) do
    Enum.reduce_while(packages, {:ok, []}, fn package, {:ok, decoded} ->
      case decode_package(package) do
        {:ok, package} -> {:cont, {:ok, [package | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      error -> error
    end
  end

  defp decode_package(%{catalog_bytes: bytes} = package) do
    with {:ok, artifact} <- decode_catalog(bytes),
         :ok <- verify_beam_modules(package.manifest, artifact, package.contents) do
      {:ok, package |> Map.put(:catalog, artifact) |> Map.delete(:catalog_bytes)}
    else
      {:error, reason} -> {:error, {:invalid_plugin_package, package.path, reason}}
    end
  end

  defp validate_paths(contents) do
    names = Enum.map(contents, fn {name, _} -> List.to_string(name) end)

    if length(names) == length(Enum.uniq(names)) and Enum.all?(contents, &safe_file?/1),
      do: :ok,
      else: {:error, :unsafe_archive_path}
  end

  @doc false
  def validate_archive(path) do
    with {:ok, entries} <- :zip.list_dir(String.to_charlist(path)),
         files <- Enum.filter(entries, &match?({:zip_file, _, _, _, _, _}, &1)),
         true <- length(files) <= @max_files,
         true <- unique_archive_names?(files),
         true <- archive_paths_safe?(files),
         true <- archive_size(files) <= @max_package_bytes do
      :ok
    else
      _ -> {:error, :invalid_or_oversized_archive}
    end
  end

  defp unique_archive_names?(files) do
    names = Enum.map(files, fn {:zip_file, name, _, _, _, _} -> List.to_string(name) end)
    length(names) == length(Enum.uniq(names))
  end

  defp archive_paths_safe?(files) do
    Enum.all?(files, fn {:zip_file, name, _, _, _, _} ->
      safe_archive_name?(List.to_string(name))
    end)
  end

  defp safe_archive_name?(path) do
    String.valid?(path) and Path.type(path) != :absolute and
      not Enum.member?(Path.split(path), "..") and not String.contains?(path, "\\")
  end

  defp archive_size(files) do
    Enum.reduce(files, 0, fn {:zip_file, _name, info, _comment, _offset, _compressed_size},
                             total ->
      if is_tuple(info) and tuple_size(info) >= 3 and elem(info, 2) == :regular do
        total + elem(info, 1)
      else
        @max_package_bytes + 1 + total
      end
    end)
  end

  defp safe_file?({name, bytes}) do
    path = List.to_string(name)

    String.valid?(path) and byte_size(bytes) <= @max_package_bytes and
      Path.type(path) != :absolute and not Enum.member?(Path.split(path), "..") and
      not String.contains?(path, "\\")
  end

  defp fetch_file(contents, name) do
    case Enum.find(contents, fn {path, _} -> List.to_string(path) == name end) do
      {_, bytes} -> {:ok, bytes}
      nil -> {:error, {:missing_package_file, name}}
    end
  end

  defp validate_manifest(manifest) when is_map(manifest) do
    required = [
      "id",
      "version",
      "otp",
      "elixir",
      "entry",
      "modules",
      "dependencies",
      "catalog",
      "catalog_sha256"
    ]

    with true <- Enum.all?(required, &Map.has_key?(manifest, &1)),
         true <- Enum.sort(Map.keys(manifest)) == Enum.sort(required),
         true <- manifest["catalog"] == "catalog.term",
         true <- valid_id?(manifest["id"]),
         true <- is_binary(manifest["version"]) and manifest["version"] != "",
         true <- manifest["otp"] == System.otp_release(),
         true <- manifest["elixir"] == major_minor(Version.parse!(System.version())),
         true <- valid_module_name?(manifest["entry"]),
         modules when is_list(modules) and modules != [] <- manifest["modules"],
         true <- modules == Enum.sort(Enum.uniq(modules)),
         true <- Enum.all?(modules, &valid_module_name?/1),
         true <- manifest["entry"] in modules,
         dependencies when is_list(dependencies) <- manifest["dependencies"],
         true <- Enum.all?(dependencies, &valid_id?/1),
         hash when is_binary(hash) <- manifest["catalog_sha256"],
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, hash) do
      :ok
    else
      _ -> {:error, :invalid_plugin_manifest}
    end
  rescue
    _ -> {:error, :invalid_plugin_manifest}
  end

  defp validate_manifest(_), do: {:error, :invalid_plugin_manifest}

  defp decode_catalog(<<131, 80, _::binary>>), do: {:error, :compressed_catalog_not_supported}

  defp decode_catalog(bytes) when is_binary(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    _ -> {:error, :invalid_catalog_term}
  end

  defp decode_catalog(_), do: {:error, :invalid_catalog_term}

  @doc false
  def ensure_catalog_schema_modules do
    Enum.reduce_while(@catalog_schema_modules, :ok, fn module, :ok ->
      case Code.ensure_loaded(module) do
        {:module, ^module} -> {:cont, :ok}
        _ -> {:halt, {:error, {:missing_catalog_schema_module, module}}}
      end
    end)
  end

  defp verify_beam_identities(manifest, contents) do
    Enum.reduce_while(manifest["modules"], :ok, fn name, :ok ->
      with {:ok, beam} <- fetch_file(contents, "ebin/#{name}.beam"),
           {:ok, ^name} <- beam_module_name(beam) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {:beam_identity_mismatch, name}}}
      end
    end)
  end

  @doc false
  def validate_atom_budget(counts) when is_list(counts) do
    if Enum.all?(counts, &(is_integer(&1) and &1 >= 0)) do
      total = Enum.sum(counts)
      atom_count = :erlang.system_info(:atom_count)
      atom_limit = :erlang.system_info(:atom_limit)

      if total <= @max_beam_atoms and atom_count + total <= atom_limit - @atom_limit_reserve,
        do: :ok,
        else: {:error, :beam_atom_budget_exceeded}
    else
      {:error, :beam_atom_budget_exceeded}
    end
  end

  def validate_atom_budget(_counts), do: {:error, :beam_atom_budget_exceeded}

  defp prepare_beam_atoms(packages) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      case prepare_package_beam_atoms(package.manifest, package.contents) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_package_beam_atoms(manifest, contents) do
    Enum.reduce_while(manifest["modules"], :ok, fn name, :ok ->
      case prepare_module_beam_atom(name, contents) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp prepare_module_beam_atom(name, contents) do
    {:ok, beam} = fetch_file(contents, "ebin/#{name}.beam")

    case :beam_lib.chunks(beam, [:atoms]) do
      {:ok, {module, _chunks}} when is_atom(module) ->
        if Atom.to_string(module) == name,
          do: :ok,
          else: {:error, {:beam_identity_mismatch, name}}

      _ ->
        {:error, {:invalid_beam, name}}
    end
  end

  defp total_beam_atom_count(modules, contents) do
    Enum.reduce_while(modules, {:ok, 0}, fn name, {:ok, total} ->
      case add_beam_atom_count(name, total, contents) do
        {:ok, next} when next <= @max_beam_atoms -> {:cont, {:ok, next}}
        {:ok, next} -> {:halt, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_beam_atom_count(name, total, contents) do
    with {:ok, beam} <- fetch_file(contents, "ebin/#{name}.beam"),
         {:ok, count} <- beam_atom_count(beam) do
      {:ok, total + count}
    end
  end

  defp beam_atom_count(<<"FOR1", size::unsigned-big-32, "BEAM", chunks::binary>> = beam)
       when size == byte_size(beam) - 8 do
    find_atom_count(chunks)
  end

  defp beam_atom_count(_), do: {:error, :invalid_beam}

  defp find_atom_count(<<chunk_id::binary-size(4), size::unsigned-big-32, rest::binary>>) do
    with {:ok, chunk, remaining} <- take_beam_chunk(rest, size) do
      atom_count_or_continue(chunk_id, chunk, remaining)
    end
  end

  defp find_atom_count(_), do: {:error, :invalid_beam}

  defp atom_count_or_continue(chunk_id, chunk, _remaining)
       when chunk_id in ["AtU8", "Atom"] do
    case chunk do
      <<count::signed-big-32, _::binary>> when count != 0 -> {:ok, abs(count)}
      _ -> {:error, :invalid_beam}
    end
  end

  defp atom_count_or_continue(_chunk_id, _chunk, remaining),
    do: find_atom_count(remaining)

  @doc false
  def verify_beam_modules(manifest, artifact, contents) do
    modules = Map.get(manifest, "modules")
    hashes = get_in(artifact, [:interface, :module_hashes])

    if valid_beam_hashes?(modules, hashes),
      do: verify_all_beam_modules(modules, hashes, contents),
      else: {:error, :invalid_beam_hashes}
  end

  defp valid_beam_hashes?(modules, hashes) do
    is_list(modules) and is_map(hashes) and Enum.sort(Map.keys(hashes)) == Enum.sort(modules)
  end

  defp verify_all_beam_modules(modules, hashes, contents) do
    Enum.reduce_while(modules, :ok, fn name, :ok ->
      case verify_beam_module(name, hashes, contents) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_beam_module(name, hashes, contents) do
    with {:ok, beam} <- fetch_file(contents, "ebin/#{name}.beam"),
         {:ok, ^name} <- beam_module_name(beam),
         expected when is_binary(expected) <- Map.get(hashes, name),
         true <- sha256(beam) == expected do
      :ok
    else
      false -> {:error, {:module_hash_mismatch, name}}
      _ -> {:error, {:invalid_beam_metadata, name}}
    end
  end

  defp validate_load_collisions(packages) do
    modules = Enum.flat_map(packages, & &1.manifest["modules"])

    if Enum.any?(modules, fn name -> :code.is_loaded(String.to_atom(name)) != false end),
      do: {:error, :module_collision},
      else: :ok
  end

  @doc false
  def load_packages(packages, order) do
    by_id = Map.new(packages, &{&1.manifest["id"], &1})

    case load_packages_in_order(order, by_id) do
      {:ok, _loaded} ->
        :ok

      {:error, reason, loaded} ->
        rollback_loaded_modules(loaded)
        {:error, reason}
    end
  end

  defp load_packages_in_order(order, by_id) do
    Enum.reduce_while(order, {:ok, []}, fn id, result ->
      load_next_package(id, result, by_id)
    end)
  end

  defp load_next_package(id, {:ok, loaded}, by_id) do
    case load_package(Map.fetch!(by_id, id)) do
      {:ok, package_loaded} -> {:cont, {:ok, package_loaded ++ loaded}}
      {:error, reason, attempted} -> {:halt, {:error, reason, attempted ++ loaded}}
    end
  end

  defp load_package(%{manifest: manifest, contents: contents}) do
    Enum.reduce_while(manifest["modules"], {:ok, []}, fn name, {:ok, loaded} ->
      {:ok, binary} = fetch_file(contents, "ebin/#{name}.beam")
      module = String.to_atom(name)

      case :code.load_binary(module, String.to_charlist(name <> ".beam"), binary) do
        {:module, ^module} ->
          {:cont, {:ok, [module | loaded]}}

        error ->
          attempted = attempted_modules(module, loaded)
          {:halt, {:error, {:beam_load_failed, name, error}, attempted}}
      end
    end)
  end

  defp attempted_modules(module, loaded) do
    if :code.is_loaded(module), do: [module | loaded], else: loaded
  end

  defp rollback_loaded_modules(modules) do
    Enum.each(modules, fn module ->
      :code.delete(module)
      :code.purge(module)
    end)
  end

  defp saved_block_ids(directory) do
    path = directory |> Path.dirname() |> Path.join("worlds/world.json")

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, data} <- Jason.decode(bytes),
             blocks when is_map(blocks) <- data["blocks"] do
          {:ok, blocks}
        else
          _ -> {:error, :invalid_saved_block_ids}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :invalid_saved_block_ids}
    end
  end

  defp find_module_atom(<<chunk_id::binary-size(4), size::unsigned-big-32, rest::binary>>) do
    with {:ok, chunk, remaining} <- take_beam_chunk(rest, size) do
      module_atom_or_continue(chunk_id, chunk, remaining)
    end
  end

  defp find_module_atom(_), do: {:error, :invalid_beam}

  defp module_atom_or_continue(chunk_id, chunk, _remaining) when chunk_id in ["AtU8", "Atom"],
    do: first_atom(chunk)

  defp module_atom_or_continue(_chunk_id, _chunk, remaining),
    do: find_module_atom(remaining)

  defp take_beam_chunk(rest, size) when byte_size(rest) >= size do
    <<chunk::binary-size(^size), tail::binary>> = rest
    padding = rem(4 - rem(size, 4), 4)

    if byte_size(tail) >= padding do
      <<_pad::binary-size(^padding), remaining::binary>> = tail
      {:ok, chunk, remaining}
    else
      {:error, :invalid_beam}
    end
  end

  defp take_beam_chunk(_rest, _size), do: {:error, :invalid_beam}

  defp first_atom(<<count::signed-big-32, rest::binary>>) when count > 0 do
    with <<length, tail::binary>> <- rest,
         true <- byte_size(tail) >= length,
         <<name::binary-size(^length), _::binary>> <- tail,
         true <- String.valid?(name) do
      {:ok, name}
    else
      _ -> {:error, :invalid_beam}
    end
  end

  defp first_atom(<<count::signed-big-32, rest::binary>>) when count < 0 do
    with {:ok, length, rest} <- decode_atom_length(rest),
         true <- length <= byte_size(rest),
         <<name::binary-size(^length), _::binary>> <- rest,
         true <- String.valid?(name) do
      {:ok, name}
    else
      _ -> {:error, :invalid_beam}
    end
  end

  defp first_atom(_), do: {:error, :invalid_beam}

  defp decode_atom_length(<<first, rest::binary>>) when (first &&& 0x08) != 0 do
    case rest do
      <<second, tail::binary>> -> {:ok, (first &&& 0xE0) <<< 3 ||| second, tail}
      _ -> {:error, :invalid_beam}
    end
  end

  defp decode_atom_length(<<first, rest::binary>>) when (first &&& 0xF0) != 0xF0,
    do: {:ok, first >>> 4, rest}

  defp decode_atom_length(_), do: {:error, :invalid_beam}

  defp valid_module_name?(name) when is_binary(name),
    do:
      String.starts_with?(name, "Elixir.WyramMods.") and Regex.match?(~r/^[A-Za-z0-9_.]+$/, name)

  defp valid_module_name?(_), do: false

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/^[a-z][a-z0-9_-]*$/, id)
  defp valid_id?(_), do: false

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp major_minor(%Version{major: major, minor: minor}), do: "#{major}.#{minor}"
end
