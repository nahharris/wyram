defmodule Wyram.Engine.Scenery.EditView do
  @moduledoc "World-owned immutable edit snapshots for visual workers."
  @history_size 1024
  def new(edited) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    chunks = Enum.map(edited, fn {key, %{data: data}} -> {key, data} end)
    :ets.insert(table, [{:stamp, 0} | chunks])
    table
  end

  def stamp(table) do
    case :ets.lookup(table, :stamp) do
      [{:stamp, value}] when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # Only the World owner can write this protected table. Data, stamp and history
  # become visible in one atomic ETS insertion after the durable edit succeeds.
  def put(table, key, data) when is_binary(data) and byte_size(data) == 8192 do
    {:ok, previous} = stamp(table)
    next = previous + 1

    true =
      :ets.insert(table, [
        {key, data},
        {:stamp, next},
        {{:change, rem(next, @history_size)}, next, key}
      ])

    next
  end

  @doc "Returns all changed chunks between two stamps, or rejects incomplete history."
  def changes(table, previous, expected)
      when is_integer(previous) and previous >= 0 and is_integer(expected) and
             expected >= previous do
    if expected - previous > @history_size,
      do: {:error, :history_gap},
      else: read_changes(table, previous, expected)
  end

  def changes(_, _, _), do: {:error, :invalid_history}

  defp read_changes(table, previous, expected) do
    with {:ok, ^expected} <- stamp(table),
         {:ok, keys} <- changed_keys(table, previous, expected),
         {:ok, ^expected} <- stamp(table) do
      {:ok, expected, keys}
    else
      {:ok, _} -> {:error, :stale}
      {:error, _} = error -> error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp changed_keys(_, stamp, stamp), do: {:ok, []}

  defp changed_keys(table, previous, expected) do
    Enum.reduce_while((previous + 1)..expected, {:ok, MapSet.new()}, fn sequence, {:ok, keys} ->
      slot = {:change, rem(sequence, @history_size)}

      case :ets.lookup(table, slot) do
        [{^slot, ^sequence, key}] -> {:cont, {:ok, MapSet.put(keys, key)}}
        _ -> {:halt, {:error, :history_gap}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, keys |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  def snapshot(table, keys, expected)
      when is_list(keys) and is_integer(expected) and expected >= 0 do
    cond do
      length(keys) > 256 -> {:error, :oversized_snapshot}
      not Enum.all?(keys, &valid_key?/1) -> {:error, :invalid_snapshot}
      true -> read(table, keys, expected)
    end
  end

  def snapshot(_, _, _), do: {:error, :invalid_snapshot}

  defp read(table, keys, expected) do
    with {:ok, ^expected} <- stamp(table),
         chunks = Enum.flat_map(keys, &:ets.lookup(table, &1)),
         {:ok, ^expected} <- stamp(table) do
      {:ok, expected, chunks}
    else
      {:ok, _} -> {:error, :stale}
      {:error, _} = error -> error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp valid_key?({x, y, z}),
    do: Enum.all?([x, y, z], &(is_integer(&1) and abs(&1) <= 62_500))

  defp valid_key?(_), do: false
end
