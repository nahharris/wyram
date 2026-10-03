defmodule Wyram.Plugin.GameCompiler do
  @moduledoc "Validates explicit game builders and resolves terrain references during compilation."

  alias Wyram.Block.Ref
  alias Wyram.Game.Config
  alias Wyram.Plugin.{Diagnostic, GameComposition, ModuleName, SourceLocation}

  @spec compile(map(), map(), map()) :: {:ok, Config.t() | nil} | {:error, [Diagnostic.t()]}
  def compile(%{game: nil}, _catalog, _dependencies), do: {:ok, nil}

  def compile(metadata, catalog, dependencies) do
    with :ok <- validate_builder(metadata),
         {:ok, config} <- build(metadata, catalog, dependencies),
         :ok <- Config.validate(config),
         :ok <- validate_references(config, metadata, catalog, dependencies) do
      {:ok, config}
    else
      {:error, %Diagnostic{} = diagnostic} ->
        {:error, [diagnostic]}

      {:error, reason} ->
        error(metadata, :invalid_game_config, "invalid game setup: #{inspect(reason)}")
    end
  rescue
    exception ->
      error(metadata, :invalid_game_config, "game setup failed: #{Exception.message(exception)}")
  catch
    kind, reason ->
      error(metadata, :invalid_game_config, "game setup failed: #{inspect({kind, reason})}")
  end

  defp validate_builder(metadata) do
    game = Map.get(metadata, :game)

    if ModuleName.valid?(game) and game in Map.get(metadata, :modules, []) and
         Code.ensure_loaded?(game) and
         (function_exported?(game, :__wyram_game__, 0) or function_exported?(game, :build, 0)),
       do: :ok,
       else: {:error, :invalid_game_builder}
  end

  defp build(metadata, catalog, dependencies) do
    if function_exported?(metadata.game, :__wyram_game__, 0),
      do: GameComposition.compile(metadata, catalog, dependencies),
      else: {:ok, metadata.game.build()}
  end

  defp validate_references(config, metadata, catalog, dependencies) do
    known = registered_ids(metadata, catalog, dependencies)

    if Enum.all?(Config.references(config), &(Ref.canonical_id(&1) in known)) do
      :ok
    else
      {:error,
       diagnostic(
         metadata,
         :unresolved_game_reference,
         "game references must name registered blocks owned by this plugin or an explicit dependency"
       )}
    end
  end

  defp registered_ids(metadata, catalog, dependencies) do
    blocks = if is_map(catalog), do: Map.get(catalog, :blocks), else: nil
    own_ids = own_registered_ids(blocks, Map.get(metadata, :id))

    dependency_ids = Enum.flat_map(metadata.dependencies, &dependency_ids(&1, dependencies))

    MapSet.new(own_ids ++ dependency_ids)
  end

  defp own_registered_ids(blocks, plugin_id) when is_list(blocks) do
    Enum.flat_map(blocks, fn block ->
      case own_registered_id(block, plugin_id) do
        nil -> []
        id -> [id]
      end
    end)
  end

  defp own_registered_ids(_, _), do: []

  defp own_registered_id(block, plugin_id) when is_map(block) do
    block_plugin_id = Map.get(block, :plugin_id)
    local_id = Map.get(block, :local_id)
    id = Map.get(block, :id)
    role_is_registered? = not Map.has_key?(block, :role) or Map.get(block, :role) == :registered

    if block_plugin_id == plugin_id and Ref.valid_plugin_id?(block_plugin_id) and
         Ref.valid_local_id?(local_id) and id == block_plugin_id <> ":" <> local_id and
         Map.get(block, :kind) == :block and role_is_registered? do
      id
    end
  end

  defp own_registered_id(_, _), do: nil

  defp dependency_ids(id, dependencies) do
    dependencies |> Map.get(id) |> dependency_declarations() |> registered_dependency_ids(id)
  end

  defp dependency_declarations(%{interface: %{declarations: declarations}}), do: declarations
  defp dependency_declarations(%{plugin: %{declarations: declarations}}), do: declarations
  defp dependency_declarations(_), do: []

  defp registered_dependency_ids(declarations, id) when is_list(declarations) do
    for %{role: :registered, kind: :block, plugin_id: ^id, local_id: local_id} <- declarations,
        Ref.valid_local_id?(local_id),
        do: id <> ":" <> local_id
  end

  defp registered_dependency_ids(_, _), do: []

  defp error(metadata, code, message), do: {:error, [diagnostic(metadata, code, message)]}

  defp diagnostic(metadata, code, message) do
    entry = Map.get(metadata, :entry)
    module = if ModuleName.valid?(entry), do: entry
    Diagnostic.new!(code, message, %SourceLocation{file: "mix.exs", line: 1, module: module})
  end
end
