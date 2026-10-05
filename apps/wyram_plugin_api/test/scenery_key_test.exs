defmodule Wyram.Scenery.KeyTest do
  use ExUnit.Case, async: true
  alias Wyram.Scenery.Key

  test "keys validate level and signed native coordinates" do
    assert {:ok, key} = Key.new({-1, -2, 3}, 2)
    assert key.position == {-1, -2, 3}
    assert key.level == 2
    assert Key.validate(key) == :ok

    for {position, level} <- [
          {{0, 0, 0}, -1},
          {{0, 0, 0}, 11},
          {{0, 0, 0}, 1.0},
          {{2_147_483_648, 0, 0}, 0},
          {{0, -2_147_483_649, 0}, 0},
          {{0, 0}, 0},
          {{0.0, 0, 0}, 0}
        ] do
      assert Key.new(position, level) == {:error, :invalid_scenery_key}
    end

    assert Key.validate(%{key | position: nil}) == {:error, :invalid_scenery_key}
    assert Key.validate(Map.put(key, :extra, true)) == {:error, :invalid_scenery_key}
    assert Key.validate(nil) == {:error, :invalid_scenery_key}
  end

  test "parent keys and world origins agree at negative and extreme coordinates" do
    assert {:ok, key} = Key.new({-1, -2, 3}, 0)
    assert {:ok, parent} = Key.parent(key)
    assert parent.position == {-1, -1, 1}
    assert parent.level == 1
    assert Key.origin(parent) == {:ok, {-32, -32, 32}}
    assert {:ok, highest} = Key.new({2_147_483_647, -2_147_483_648, 0}, 10)
    assert Key.origin(highest) == {:ok, {35_184_372_072_448, -35_184_372_088_832, 0}}
    assert Key.parent(highest) == {:error, :invalid_scenery_key}
    assert Key.origin(nil) == {:error, :invalid_scenery_key}
  end
end
