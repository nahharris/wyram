defmodule Wyram.Engine.Scenery.Fetch do
  @moduledoc "Collects saved edit samples in bounded batches before visual generation."
  alias Wyram.Engine.Native
  alias Wyram.Engine.Scenery.{CachedGeneration, EditView}
  alias Wyram.Scenery.Key

  def run(%{generation: %{resource: nil}}, _keys),
    do: {:error, :unsupported_scenery_generation}

  def run(%{generation: %{resource: resource}} = model, keys) when is_list(keys) do
    cond do
      length(keys) > 2 -> {:error, :oversized_scenery_batch}
      not Enum.all?(keys, &(Key.validate(&1) == :ok)) -> {:error, :invalid_scenery_key}
      true -> generate(model, resource, keys)
    end
  end

  def run(_, _), do: {:error, :invalid_scenery_batch}

  defp generate(model, resource, keys) do
    with :ok <- current?(model),
         {:ok, inputs} <- collect(model, resource, keys),
         :ok <- current?(model),
         {:ok, binaries} <- CachedGeneration.run(model, resource, inputs),
         :ok <- current?(model) do
      {:ok, binaries}
    end
  end

  defp collect(model, resource, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, inputs} ->
      wire = {key.position, key.level}

      with {:ok, chunks} <- Native.scenic_sample_chunks(resource, wire),
           {:ok, samples} <- samples(model, resource, wire, chunks) do
        {:cont, {:ok, [{wire, samples} | inputs]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp samples(model, resource, key, chunks) do
    chunks
    |> Enum.chunk_every(256)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, parts} ->
      with {:ok, _, edited} <- EditView.snapshot(model.edits, batch, model.stamp),
           {:ok, samples} <- extract(resource, key, edited) do
        {:cont, {:ok, [samples | parts]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp extract(_, _, []), do: {:ok, <<>>}
  defp extract(resource, key, edited), do: Native.extract_scenic_samples(resource, key, edited)

  defp current?(model) do
    case EditView.stamp(model.edits) do
      {:ok, stamp} when stamp == model.stamp -> :ok
      {:ok, _} -> {:error, :stale}
      error -> error
    end
  end
end
