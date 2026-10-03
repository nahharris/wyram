defmodule Wyram.Plugin.CatalogCollector do
  @moduledoc false
  alias Wyram.Plugin.{Diagnostic, Kind}

  def collect(metadata, owned) do
    initial = %{seen: MapSet.new(), active: [], modules: [], blocks: [], content: []}

    roots = [
      %{kind: :block, module: metadata.entry, source: source(metadata.entry)} | metadata.catalogs
    ]

    Enum.reduce_while(roots, {:ok, initial}, fn root, {:ok, state} ->
      case visit(root, metadata.entry, owned, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp visit(root, entry, owned, state) do
    cond do
      root.module in state.active ->
        error(:catalog_cycle, "catalog inclusion cycle", root)

      MapSet.member?(state.seen, root.module) ->
        error(:duplicate_catalog, "catalog included more than once", root)

      MapSet.size(state.seen) >= 1024 ->
        error(:catalog_budget_exceeded, "too many catalog modules", root)

      root.module not in owned ->
        error(
          :module_ownership_mismatch,
          "catalog is outside this plugin's compiled application",
          root
        )

      true ->
        collect_module(root, entry, owned, state)
    end
  end

  defp collect_module(root, entry, owned, state) do
    with {:ok, catalog} <- catalog_metadata(root, entry),
         :ok <- validate_catalog(catalog, root, entry) do
      state = %{
        state
        | seen: MapSet.put(state.seen, root.module),
          active: [root.module | state.active],
          modules: state.modules ++ [root.module],
          blocks: state.blocks ++ root.module.__wyram_declarations__(),
          content: state.content ++ catalog.declarations
      }

      collect_includes(catalog.includes, catalog.kind, entry, owned, state)
      |> case do
        {:ok, state} -> {:ok, %{state | active: tl(state.active)}}
        error -> error
      end
    end
  end

  defp collect_includes(includes, kind, entry, owned, state) do
    Enum.reduce_while(includes, {:ok, state}, fn included, {:ok, state} ->
      case visit(Map.put(included, :kind, kind), entry, owned, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp catalog_metadata(%{module: entry}, entry) do
    {:ok, %{plugin: entry, kind: :block, includes: [], declarations: []}}
  end

  defp catalog_metadata(root, _entry) do
    if Code.ensure_loaded?(root.module) and function_exported?(root.module, :__wyram_catalog__, 0) do
      {:ok, root.module.__wyram_catalog__()}
    else
      error(:missing_catalog, "module does not use Wyram.Plugin.Catalog", root)
    end
  end

  defp validate_catalog(catalog, root, entry) do
    cond do
      catalog.plugin != entry ->
        error(:catalog_ownership_mismatch, "catalog belongs to another plugin", root)

      catalog.kind not in Kind.kinds() ->
        error(:catalog_kind_mismatch, "catalog has an unsupported content kind", root)

      not is_nil(Map.get(root, :kind)) and catalog.kind != root.kind ->
        error(:catalog_kind_mismatch, "included catalog has the wrong content kind", root)

      true ->
        :ok
    end
  end

  defp source(module), do: %Wyram.Plugin.SourceLocation{file: "mix.exs", line: 1, module: module}

  defp error(code, message, root),
    do: {:error, Diagnostic.new!(code, "#{message}: #{inspect(root.module)}", root.source)}
end
