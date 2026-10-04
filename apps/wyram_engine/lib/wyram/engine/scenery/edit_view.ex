defmodule Wyram.Engine.Scenery.EditView do
  @moduledoc "World-owned immutable edit snapshots for visual workers."
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

  # Only the World owner can write this protected table. Data and the stamp
  # become visible in one atomic ETS insertion after the durable edit succeeds.
  def put(table, key, data) when is_binary(data) and byte_size(data) == 8192 do
    {:ok, previous} = stamp(table)
    next = previous + 1
    true = :ets.insert(table, [{key, data}, {:stamp, next}])
    next
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
