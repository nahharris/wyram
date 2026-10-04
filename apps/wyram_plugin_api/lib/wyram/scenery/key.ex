defmodule Wyram.Scenery.Key do
  @moduledoc "Visual tile coordinates at a specified resolution level."
  @enforce_keys [:position, :level]
  defstruct [:position, :level]
  @type t :: %__MODULE__{position: {integer(), integer(), integer()}, level: non_neg_integer()}

  @type error :: {:error, :invalid_scenery_key}
  @spec new(term(), term()) :: {:ok, t()} | error()
  def new(position, level) do
    key = %__MODULE__{position: position, level: level}
    with :ok <- validate(key), do: {:ok, key}
  end

  @spec validate(term()) :: :ok | error()
  def validate(%__MODULE__{position: {x, y, z}, level: level} = key)
      when map_size(key) == 3 and is_integer(level) and level in 0..10 do
    if Enum.all?([x, y, z], &(is_integer(&1) and &1 in -2_147_483_648..2_147_483_647)),
      do: :ok,
      else: {:error, :invalid_scenery_key}
  end

  def validate(_), do: {:error, :invalid_scenery_key}

  @spec parent(term()) :: {:ok, t()} | error()
  def parent(%__MODULE__{} = key) do
    with :ok <- validate(key) do
      position =
        key.position |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1, 2)) |> List.to_tuple()

      new(position, key.level + 1)
    end
  end

  def parent(_), do: {:error, :invalid_scenery_key}

  @spec origin(term()) :: {:ok, {integer(), integer(), integer()}} | error()
  def origin(%__MODULE__{} = key) do
    with :ok <- validate(key) do
      width = 16 * Integer.pow(2, key.level)
      position = key.position |> Tuple.to_list() |> Enum.map(&(&1 * width)) |> List.to_tuple()
      {:ok, position}
    end
  end

  def origin(_), do: {:error, :invalid_scenery_key}
end
