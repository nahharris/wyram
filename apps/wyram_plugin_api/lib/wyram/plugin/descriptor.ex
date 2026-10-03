defmodule Wyram.Plugin.Descriptor do
  @moduledoc "Shared compiler/runtime contract for supported native block descriptors."

  @spec valid?(term()) :: boolean()
  def valid?(descriptor) when is_map(descriptor) do
    required = [:geometry, :collision, :material]

    Enum.all?(required, &Map.has_key?(descriptor, &1)) and
      Enum.all?(descriptor, fn {field, value} -> valid_field?(field, value) end) and
      (not Map.has_key?(descriptor, :liquid) or descriptor.collision == %{primitive: :none})
  end

  def valid?(_), do: false

  @spec valid_field?(atom(), term()) :: boolean()
  def valid_field?(:geometry, %{primitive: :cube} = value), do: map_size(value) == 1

  def valid_field?(:collision, %{primitive: primitive} = value)
      when primitive in [:cube, :none], do: map_size(value) == 1

  def valid_field?(:material, %{color: color, mode: mode} = value) do
    valid_rgb?(color) and valid_material_mode?(mode, value)
  end

  def valid_field?(:liquid, %{flow_ms: ms, max_level: level} = value) do
    map_size(value) == 2 and is_integer(ms) and ms in 100..5000 and
      is_integer(level) and level in 1..7
  end

  def valid_field?(_, _), do: false

  defp valid_material_mode?(:blended, %{opacity: opacity} = value),
    do: map_size(value) == 3 and is_integer(opacity) and opacity in 1..254

  defp valid_material_mode?(mode, value) when mode in [:opaque, :emissive],
    do: map_size(value) == 2

  defp valid_material_mode?(_, _), do: false
  defp valid_rgb?({r, g, b}), do: Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255))
  defp valid_rgb?(_), do: false
end
