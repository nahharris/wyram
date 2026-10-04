defmodule Wyram.Engine.SceneryNativeTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Native
  alias Wyram.Scenery.Key

  @air :binary.copy(<<0>>, 8192)

  test "the loaded NIF retains top colors independently of volume material" do
    data =
      for y <- 0..15, into: <<>> do
        material = if rem(y, 2) == 0, do: 3, else: 9
        :binary.copy(<<material::little-16>>, 256)
      end

    chunks =
      for octant <- 0..7 do
        {{rem(octant, 2), rem(div(octant, 2), 2), div(octant, 4)}, data}
      end

    assert {:ok, leaves} = Native.import_visual_chunks(chunks)
    assert {:ok, [parent]} = Native.reduce_visual_tiles([leaves])

    assert parent ==
             <<"WSL2", 1, 1, 0, 0, 0::little-signed-32, 0::little-signed-32, 0::little-signed-32,
               3::little-16, 8::little-32, 255, 1, 9::little-16>>
  end

  test "batched chunk imports and parent reduction agree with public tile coordinates" do
    chunks =
      for octant <- 0..7 do
        position = {rem(octant, 2), rem(div(octant, 2), 2), div(octant, 4)}
        {position, :binary.copy(<<7::little-16>>, 4096)}
      end

    assert {:ok, tiles} = Native.import_visual_chunks(chunks)
    assert length(tiles) == 8
    assert {:ok, [parent]} = Native.reduce_visual_tiles([Enum.reverse(tiles)])

    assert <<"WSL1", 1, 1, 0, 0, x::little-signed-32, y::little-signed-32, z::little-signed-32,
             7::little-16, 8::little-32, 255, 0>> = parent

    assert {:ok, expected} = Key.new({0, 0, 0}, 1)
    assert {x, y, z} == expected.position
    assert Key.origin(expected) == {:ok, {0, 0, 0}}
  end

  test "empty negative sibling tiles reduce without a cell payload" do
    chunks =
      for octant <- 0..7 do
        position = {-2 + rem(octant, 2), -2 + rem(div(octant, 2), 2), -2 + div(octant, 4)}
        {position, @air}
      end

    assert {:ok, tiles} = Native.import_visual_chunks(chunks)
    assert Enum.all?(tiles, &(byte_size(&1) == 20))
    assert {:ok, [parent]} = Native.reduce_visual_tiles([tiles])

    assert <<"WSL1", 1, 0, 0, 0, -1::little-signed-32, -1::little-signed-32,
             -1::little-signed-32>> = parent
  end

  test "native batches reject oversized, malformed and incomplete work" do
    assert Native.import_visual_chunks(List.duplicate({{0, 0, 0}, @air}, 17)) ==
             {:error, "oversized visual chunk batch"}

    assert Native.import_visual_chunks([{{0, 0, 0}, <<0>>}]) ==
             {:error, "invalid visual chunk"}

    assert Native.reduce_visual_tiles(List.duplicate([], 9)) ==
             {:error, "oversized visual reduction batch"}

    assert Native.reduce_visual_tiles([[]]) == {:error, "incomplete visual sibling batch"}

    assert Native.reduce_visual_tiles([List.duplicate(<<0>>, 8)]) ==
             {:error, "invalid visual tile encoding"}

    assert {:ok, [empty]} = Native.import_visual_chunks([{{0, 0, 0}, @air}])

    assert Native.reduce_visual_tiles([List.duplicate(empty, 8)]) ==
             {:error, "invalid visual sibling batch"}

    assert Native.import_visual_chunks([]) == {:ok, []}
    assert Native.reduce_visual_tiles([]) == {:ok, []}
  end
end
