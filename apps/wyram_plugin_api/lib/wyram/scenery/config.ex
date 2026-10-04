defmodule Wyram.Scenery.Config do
  @moduledoc "Visual scenery quality and bounded resource policy."
  defstruct distance: 1024,
            max_level: 5,
            detail_distance: 64,
            max_tiles: 1024,
            workers: 2,
            cache_bytes: 67_108_864,
            mesh_bytes: 67_108_864

  @type t :: %__MODULE__{
          distance: pos_integer(),
          max_level: pos_integer(),
          detail_distance: pos_integer(),
          max_tiles: pos_integer(),
          workers: pos_integer(),
          cache_bytes: pos_integer(),
          mesh_bytes: pos_integer()
        }
  @type result :: {:ok, t()} | {:error, :invalid_scenery_config}
  @fields [
    :distance,
    :max_level,
    :detail_distance,
    :max_tiles,
    :workers,
    :cache_bytes,
    :mesh_bytes
  ]
  @limits %{
    distance: 128..4096,
    max_level: 1..6,
    detail_distance: 16..128,
    max_tiles: 64..4096,
    workers: 1..2,
    cache_bytes: 1_048_576..268_435_456,
    mesh_bytes: 4_194_304..268_435_456
  }

  @spec new(term()) :: result()
  def new(attrs) when is_map(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)) do
      config = struct!(__MODULE__, attrs)
      with :ok <- validate(config), do: {:ok, config}
    else
      {:error, :invalid_scenery_config}
    end
  end

  def new(_), do: {:error, :invalid_scenery_config}

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid scenery policy: #{reason}"
    end
  end

  @spec validate(term()) :: :ok | {:error, :invalid_scenery_config}
  def validate(%__MODULE__{} = config) when map_size(config) == 8 do
    valid =
      Enum.sort(Map.keys(config)) == Enum.sort([:__struct__ | @fields]) and
        Enum.all?(@limits, fn {field, range} -> integer_in?(Map.fetch!(config, field), range) end) and
        rem(config.distance, 16) == 0 and config.max_tiles * 40_980 <= config.cache_bytes

    if valid, do: :ok, else: {:error, :invalid_scenery_config}
  end

  def validate(_), do: {:error, :invalid_scenery_config}
  defp integer_in?(value, range), do: is_integer(value) and value in range
end
