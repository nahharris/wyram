defmodule Wyram.Engine.LodWireTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.LodWire

  @empty <<"LT01", 39_304::little-16, 0::80>>

  test "versioned batches retain epoch, signed tile coordinates and revisions" do
    assert <<"WL01", 7::little-64, 1::little-16, 2, -1::little-signed-32, -3::little-signed-32,
             4::little-signed-32, 9::little-64, 16::little-32, @empty::binary>> =
             LodWire.encode(7, [{{2, -1, -3, 4}, 9, @empty}])
  end

  test "transport is capped independently of worker counts" do
    body = "LT01" <> :binary.copy(<<0>>, 600_000)
    assert byte_size(LodWire.encode(0, [{{16, 0, 0, 0}, 0, body}])) < 1_048_576

    assert_raise ArgumentError, fn ->
      LodWire.encode(0, [{{16, 0, 0, 0}, 0, body}, {{16, 1, 0, 0}, 0, body}])
    end
  end

  test "invalid keys, revisions, epochs and payloads are rejected" do
    for key <- [{1, 0, 0, 0}, {32, 0, 0, 0}, {2, 50_000, 0, 0}] do
      assert_raise ArgumentError, fn -> LodWire.encode(0, [{key, 0, @empty}]) end
    end

    for revision <- [-1, 18_446_744_073_709_551_616, 1.5] do
      assert_raise ArgumentError, fn -> LodWire.encode(0, [{{2, 0, 0, 0}, revision, @empty}]) end
    end

    assert_raise ArgumentError, fn -> LodWire.encode(-1, [{{2, 0, 0, 0}, 0, @empty}]) end
    assert_raise ArgumentError, fn -> LodWire.encode(0, []) end
    assert_raise ArgumentError, fn -> LodWire.encode(0, [{{2, 0, 0, 0}, 0, "bad"}]) end

    assert_raise ArgumentError, fn ->
      LodWire.encode(0, List.duplicate({{2, 0, 0, 0}, 0, @empty}, 3))
    end
  end
end
