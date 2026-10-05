defmodule Wyram.Engine.LodWire do
  @moduledoc "Versioned visual-only tile batches, independent of existing chunk transport."
  @limit 1_048_576
  @max_revision 18_446_744_073_709_551_615

  def encode(epoch, tiles) when is_list(tiles) and length(tiles) in 1..2 do
    unless revision?(epoch), do: raise(ArgumentError, "invalid LOD epoch")
    records = Enum.map(tiles, &record/1)
    keys = Enum.map(tiles, &elem(&1, 0))
    unless Enum.uniq(keys) == keys, do: raise(ArgumentError, "duplicate LOD tile")
    bytes = 14 + Enum.reduce(records, 0, &(IO.iodata_length(&1) + &2))
    if bytes > @limit, do: raise(ArgumentError, "LOD transport batch exceeds 1 MiB")
    IO.iodata_to_binary([<<"WL01", epoch::little-64, length(tiles)::little-16>>, records])
  end

  def encode(_, _), do: raise(ArgumentError, "expected one or two LOD tiles")

  defp record({{size, x, y, z}, revision, <<"LT01", _::binary>> = payload})
       when size in [2, 4, 8, 16] and is_integer(x) and is_integer(y) and is_integer(z) do
    width = 32 * size

    unless revision?(revision) and byte_size(payload) in 16..@limit and
             Enum.all?([x, y, z], fn coordinate ->
               coordinate * width - size >= -1_000_000 and
                 coordinate * width + width + size - 1 <= 1_000_000
             end),
           do: raise(ArgumentError, "invalid LOD tile bounds, revision or payload")

    [
      <<size, x::little-signed-32, y::little-signed-32, z::little-signed-32, revision::little-64,
        byte_size(payload)::little-32>>,
      payload
    ]
  end

  defp record(_), do: raise(ArgumentError, "invalid LOD tile")
  defp revision?(value), do: is_integer(value) and value >= 0 and value <= @max_revision
end
