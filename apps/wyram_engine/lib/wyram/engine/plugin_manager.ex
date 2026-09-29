defmodule Wyram.Engine.PluginManager do
  @moduledoc "Validates and loads trusted compiled plugin packages at startup."
  use GenServer

  @max_package_bytes 16 * 1024 * 1024
  @max_files 128

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec blocks() :: %{String.t() => pos_integer()}
  def blocks, do: GenServer.call(__MODULE__, :blocks)

  @spec block_colors() :: %{pos_integer() => [integer()]}
  def block_colors, do: GenServer.call(__MODULE__, :block_colors)

  @spec terrain_palette() :: [pos_integer()]
  def terrain_palette, do: GenServer.call(__MODULE__, :terrain_palette)

  @spec plugin_versions() :: %{String.t() => String.t()}
  def plugin_versions, do: GenServer.call(__MODULE__, :plugin_versions)

  @impl true
  def init(options) do
    directory = Keyword.fetch!(options, :directory)

    with {:ok, packages} <- scan(directory),
         :ok <- validate_graph(packages),
         {:ok, plugins} <- load_packages(packages),
         {:ok, state} <- registry(plugins, directory) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:blocks, _from, state), do: {:reply, state.blocks, state}
  def handle_call(:block_colors, _from, state), do: {:reply, state.colors, state}
  def handle_call(:terrain_palette, _from, state), do: {:reply, state.palette, state}
  def handle_call(:plugin_versions, _from, state), do: {:reply, state.versions, state}

  defp scan(directory) do
    directory
    |> Path.join("*.wyrplug")
    |> String.replace("\\", "/")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, collected} ->
      case read_package(path) do
        {:ok, package} -> {:cont, {:ok, [package | collected]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "no game plugin installed in #{directory}"}
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      error -> error
    end
  end

  defp read_package(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= @max_package_bytes,
         {:ok, contents} <- :zip.extract(String.to_charlist(path), [:memory]),
         true <- length(contents) <= @max_files,
         :ok <- validate_paths(contents),
         {:ok, manifest_bytes} <- fetch_file(contents, "manifest.json"),
         {:ok, manifest} <- Jason.decode(manifest_bytes),
         :ok <- validate_manifest(manifest, contents) do
      {:ok, %{path: path, manifest: manifest, contents: contents}}
    else
      false -> {:error, "invalid or oversized plugin package: #{path}"}
      {:error, reason} -> {:error, "plugin #{path}: #{inspect(reason)}"}
    end
  end

  defp validate_paths(contents) do
    case Enum.all?(contents, &safe_file?/1) do
      true -> :ok
      false -> {:error, :unsafe_archive_path}
    end
  end

  defp safe_file?({name, bytes}) do
    path = List.to_string(name)

    String.valid?(path) and byte_size(bytes) <= @max_package_bytes and
      Path.type(path) != :absolute and
      not Enum.member?(Path.split(path), "..") and
      not String.contains?(path, "\\")
  end

  defp fetch_file(contents, name) do
    case Enum.find(contents, fn {path, _} -> List.to_string(path) == name end) do
      {_, bytes} -> {:ok, bytes}
      nil -> {:error, "missing #{name}"}
    end
  end

  defp validate_manifest(manifest, contents) do
    with :ok <- validate_fields(manifest),
         :ok <- validate_structure(manifest, contents) do
      validate_compatibility(manifest)
    end
  end

  defp validate_fields(manifest) do
    required = ["id", "version", "api", "otp", "elixir", "entry", "modules", "dependencies"]

    cond do
      not is_map(manifest) ->
        {:error, :invalid_manifest}

      not Enum.all?(required, &Map.has_key?(manifest, &1)) ->
        {:error, :missing_manifest_fields}

      true ->
        :ok
    end
  end

  defp validate_structure(manifest, contents) do
    cond do
      not valid_id?(manifest["id"]) ->
        {:error, :invalid_plugin_id}

      not is_list(manifest["modules"]) or manifest["modules"] == [] ->
        {:error, :missing_modules}

      not is_list(manifest["dependencies"]) or
          not Enum.all?(manifest["dependencies"], &is_binary/1) ->
        {:error, :invalid_dependencies}

      not Enum.all?(manifest["modules"], &valid_module?(&1, contents)) ->
        {:error, :invalid_modules}

      manifest["entry"] not in manifest["modules"] ->
        {:error, :missing_entry}

      true ->
        :ok
    end
  end

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, id)
  defp valid_id?(_), do: false

  defp validate_compatibility(manifest) do
    cond do
      manifest["api"] != Wyram.PluginApi.version() ->
        {:error, :incompatible_api}

      manifest["otp"] != System.otp_release() ->
        {:error, :incompatible_otp}

      manifest["elixir"] != major_minor(Version.parse!(System.version())) ->
        {:error, :incompatible_elixir}

      true ->
        :ok
    end
  end

  defp major_minor(%Version{major: major, minor: minor}), do: "#{major}.#{minor}"

  defp valid_module?(name, contents) when is_binary(name) do
    String.starts_with?(name, "Elixir.WyramMods.") and
      Regex.match?(~r/^[A-Za-z0-9_.]+$/, name) and
      match?({:ok, _}, fetch_file(contents, "ebin/#{name}.beam"))
  end

  defp valid_module?(_, _), do: false

  defp validate_graph(packages) do
    manifests = Enum.map(packages, & &1.manifest)
    ids = Enum.map(manifests, & &1["id"])
    modules = Enum.flat_map(manifests, & &1["modules"])
    by_id = Map.new(manifests, &{&1["id"], &1})

    cond do
      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :duplicate_plugin_id}

      length(Enum.uniq(modules)) != length(modules) ->
        {:error, :duplicate_module}

      Enum.any?(modules, fn name -> :code.is_loaded(String.to_atom(name)) != false end) ->
        {:error, :module_collision}

      Enum.any?(manifests, fn manifest ->
        Enum.any?(manifest["dependencies"], fn dependency ->
          not Map.has_key?(by_id, dependency)
        end)
      end) ->
        {:error, :missing_dependency}

      true ->
        :ok
    end
  end

  defp load_packages(packages) do
    Enum.reduce_while(packages, {:ok, []}, fn package, {:ok, loaded} ->
      case load_package(package) do
        {:ok, plugin} -> {:cont, {:ok, [plugin | loaded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plugins} -> {:ok, Enum.reverse(plugins)}
      error -> error
    end
  end

  defp load_package(%{manifest: manifest, contents: contents}) do
    result =
      Enum.reduce_while(manifest["modules"], :ok, fn name, :ok ->
        {:ok, binary} = fetch_file(contents, "ebin/#{name}.beam")
        module = String.to_atom(name)

        case :code.load_binary(module, String.to_charlist(name <> ".beam"), binary) do
          {:module, ^module} -> {:cont, :ok}
          error -> {:halt, {:error, {:beam_load_failed, name, error}}}
        end
      end)

    case result do
      :ok -> {:ok, {manifest, String.to_atom(manifest["entry"])}}
      error -> error
    end
  end

  defp registry(plugins, directory) do
    definitions =
      for {manifest, module} <- plugins, block <- module.blocks() do
        {manifest["id"] <> ":" <> block.name, block}
      end

    case definitions == [] or
           length(Enum.uniq_by(definitions, &elem(&1, 0))) != length(definitions) do
      true -> {:error, :invalid_block_definitions}
      false -> build_registry(plugins, definitions, directory)
    end
  end

  defp build_registry(plugins, definitions, directory) do
    ordered = Enum.sort_by(definitions, &elem(&1, 0))
    blocks = assign_block_ids(ordered, directory)
    colors = Map.new(ordered, fn {name, block} -> {Map.fetch!(blocks, name), block.color} end)

    terrain =
      Enum.find_value(plugins, fn {_manifest, module} ->
        case module.terrain() do
          {:layered, profile} -> profile
          :none -> nil
        end
      end)

    with %{surface: surface, soil: soil, rock: rock} <- terrain,
         {:ok, palette} <- palette(blocks, [surface, soil, rock]) do
      {:ok,
       %{
         blocks: blocks,
         colors: colors,
         palette: palette,
         versions: Map.new(plugins, fn {manifest, _} -> {manifest["id"], manifest["version"]} end)
       }}
    else
      _ -> {:error, :missing_terrain_profile}
    end
  end

  defp assign_block_ids(ordered, directory) do
    existing = saved_block_ids(ordered, directory)
    names = Enum.map(ordered, &elem(&1, 0))
    next_id = existing |> Map.values() |> Enum.max(fn -> 0 end)

    {ids, _next_id} =
      Enum.reduce(names, {Map.take(existing, names), next_id}, fn name, {ids, id} ->
        if Map.has_key?(ids, name) do
          {ids, id}
        else
          {Map.put(ids, name, id + 1), id + 1}
        end
      end)

    ids
  end

  defp saved_block_ids(ordered, directory) do
    path = directory |> Path.dirname() |> Path.join("worlds/world.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- is_map(data["plugins"]) do
      case data["blocks"] do
        blocks when is_map(blocks) -> blocks
        _ -> legacy_block_ids(ordered, data["plugins"])
      end
    else
      _ -> %{}
    end
  end

  defp legacy_block_ids(ordered, plugins) do
    ordered
    |> Enum.filter(fn {name, _} ->
      [plugin_id | _] = String.split(name, ":", parts: 2)
      Map.has_key?(plugins, plugin_id)
    end)
    |> Enum.with_index(1)
    |> Map.new(fn {{name, _}, id} -> {name, id} end)
  end

  defp palette(blocks, names) do
    ids = Enum.map(names, &Map.get(blocks, &1))
    if Enum.all?(ids, &is_integer/1), do: {:ok, ids}, else: {:error, :unknown_terrain_block}
  end
end
