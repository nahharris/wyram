defmodule Wyram.Plugin.Compiler.BeamTest do
  use ExUnit.Case, async: true

  alias Wyram.Plugin.Compiler.Beam

  test "equivalent checker maps produce identical BEAMs without changing other chunks" do
    left = checker_bytes([{:module, :block}, {:source, :template}])
    right = checker_bytes([{:source, :template}, {:module, :block}])
    refute left == right
    assert :erlang.binary_to_term(left) == :erlang.binary_to_term(right)
    chunks = [{~c"AtU8", <<1::32, 4, "test">>}, {~c"Code", <<1, 2, 3>>}, {~c"LitT", <<4, 5, 6>>}]
    assert {:ok, first} = :beam_lib.build_module(chunks ++ [{~c"ExCk", left}])
    assert {:ok, second} = :beam_lib.build_module(chunks ++ [{~c"ExCk", right}])
    assert {:ok, canonical} = Beam.canonical_bytes(first)
    assert {:ok, ^canonical} = Beam.canonical_bytes(second)
    assert {:ok, ^canonical} = Beam.canonical_bytes(canonical)
    assert {:ok, _, normalized} = :beam_lib.all_chunks(canonical)
    assert Enum.take(normalized, 3) == chunks

    assert {:ok, changed} =
             :beam_lib.build_module(
               List.keyreplace(chunks, ~c"Code", 0, {~c"Code", <<9>>}) ++ [{~c"ExCk", left}]
             )

    assert {:ok, changed} = Beam.canonical_bytes(changed)
    refute changed == canonical
  end

  defp checker_bytes(pairs) do
    payload =
      Enum.map(pairs, fn {key, value} -> [without_version(key), without_version(value)] end)

    IO.iodata_to_binary([<<131, 116, length(pairs)::32>>, payload])
  end

  defp without_version(term) do
    <<131, payload::binary>> = :erlang.term_to_binary(term)
    payload
  end
end
