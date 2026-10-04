defmodule Wyram.Engine.ChunkWire do
  @moduledoc "Versioned packed snapshot batches. A zero-length payload explicitly replaces a chunk with air."
  @air :binary.copy(<<0>>, 8192)

  def encode(chunks) when length(chunks) <= 16,
    do: [<<"WYC1", length(chunks)::16>> | Enum.map(chunks, &encode_chunk/1)]

  def encode(_), do: raise(ArgumentError, "oversized chunk batch")

  defp encode_chunk({{x, y, z}, %{revision: revision, data: data}})
       when byte_size(data) == 8192 and x in -2_147_483_648..2_147_483_647 and
              y in -2_147_483_648..2_147_483_647 and z in -2_147_483_648..2_147_483_647 and
              revision in 0..18_446_744_073_709_551_615 do
    data = if data == @air, do: <<>>, else: data
    [<<x::signed-32, y::signed-32, z::signed-32, revision::64, byte_size(data)::16>>, data]
  end

  defp encode_chunk(_), do: raise(ArgumentError, "invalid packed chunk")
end
