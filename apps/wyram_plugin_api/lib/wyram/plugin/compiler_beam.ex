defmodule Wyram.Plugin.Compiler.Beam do
  @moduledoc false

  # Elixir checker metadata can serialize equivalent maps in VM-dependent order.
  # Normalize this non-executable chunk before hashing and packaging the BEAM.
  def canonical_bytes(bytes) when is_binary(bytes) do
    with {:ok, _module, chunks} <- :beam_lib.all_chunks(bytes) do
      chunks = Enum.map(chunks, &canonical_chunk/1)
      :beam_lib.build_module(chunks)
    end
  end

  defp canonical_chunk({~c"ExCk", bytes}) do
    # Only invoked on trusted local compiler output, never installed package input.
    metadata = :erlang.binary_to_term(bytes)
    {~c"ExCk", :erlang.term_to_binary(metadata, [:deterministic])}
  end

  defp canonical_chunk(chunk), do: chunk
end
