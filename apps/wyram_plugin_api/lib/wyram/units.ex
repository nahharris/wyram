defmodule Wyram.Units do
  @moduledoc """
  Authored distances use blocks and an eight-pixel design grid.
  For example, 1\\3 means one block plus three pixels (1.375 blocks).
  Physics and positions remain continuous block distances.
  """
  @pixels_per_block 8
  def pixels_per_block, do: @pixels_per_block

  @doc "Convert a pixel distance, including fractional centers and signed bone offsets, to blocks."
  def pixels(value) when is_number(value), do: value / @pixels_per_block
  @doc "Convert canonical non-negative block/pixel parts to continuous block units."
  def blocks(blocks, pixels \\ 0)

  def blocks(blocks, pixels)
      when is_integer(blocks) and blocks >= 0 and is_integer(pixels) and pixels in 0..7,
      do: blocks + pixels(pixels)

  def blocks(_, _), do: raise(ArgumentError, "expected non-negative blocks and 0..7 pixels")

  def notation(blocks, pixels) do
    _ = blocks(blocks, pixels)
    "#{blocks}\\#{pixels}"
  end
end
