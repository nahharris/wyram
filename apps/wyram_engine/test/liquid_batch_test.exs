defmodule Wyram.Engine.LiquidBatchTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Native

  test "packed liquid discovery, sampling and conditional edits operate in batches" do
    data = :binary.copy(<<0, 0>>, 4096)
    edits = [{0, 0, 0, 0, 10}, {15, 15, 15, 0, 11}]
    assert {:ok, changed} = Native.compare_write_blocks(data, edits)
    assert {:ok, [10, 11, 0]} = Native.read_blocks(changed, [{0, 0, 0}, {15, 15, 15}, {1, 1, 1}])
    assert {:ok, [{0, 0, 0}, {15, 15, 15}]} = Native.liquid_positions(changed, [10, 11])
    assert {:error, _} = Native.compare_write_blocks(changed, edits)
    assert {:error, _} = Native.compare_write_blocks(data, [hd(edits), hd(edits)])
    assert {:error, _} = Native.read_blocks(data, [{16, 0, 0}])
  end
end
