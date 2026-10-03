defmodule Wyram.Engine.ChunkWireTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.ChunkWire

  test "bounded packets encode coordinates, revisions, packed bytes and explicit empty replacement" do
    packed = :binary.copy(<<7>>, 8192)
    air = :binary.copy(<<0>>, 8192)

    wire =
      ChunkWire.encode([
        {{-1, -12, 0}, %{revision: 18_446_744_073_709_551_615, data: packed}},
        {{0, 19, 0}, %{revision: 2, data: air}}
      ])
      |> IO.iodata_to_binary()

    assert <<"WYC1", 2::16, -1::signed-32, -12::signed-32, 0::signed-32,
             18_446_744_073_709_551_615::64, 8192::16, ^packed::binary-size(8192), 0::signed-32,
             19::signed-32, 0::signed-32, 2::64, 0::16>> = wire

    assert byte_size(wire) == 6 + 2 * 22 + 8192

    assert_raise ArgumentError, fn ->
      ChunkWire.encode(List.duplicate({{0, 0, 0}, %{revision: 0, data: air}}, 17))
    end

    assert_raise ArgumentError, fn ->
      ChunkWire.encode([{{0, 0, 0}, %{revision: 0, data: <<1>>}}])
    end
  end
end
