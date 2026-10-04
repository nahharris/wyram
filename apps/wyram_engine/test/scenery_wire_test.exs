defmodule Wyram.Engine.Scenery.WireTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.{Plan, Wire}
  alias Wyram.Scenery.{Config, Key}

  test "the plan header and node records have explicit portable layouts" do
    config = Config.new!(%{})
    {:ok, key} = Key.new({-1, 0, 2}, 1)
    plan = %{roots: [key], order: [key], nodes: %{key => []}, content: 7}
    packet = Wire.plan(3, 5, plan, config) |> IO.iodata_to_binary()

    assert packet ==
             <<"WSP1", 3::64, 7::64, 5::64, 1024::16, 67_108_864::32, 67_108_864::32, 1::16,
               1::16, 0::16, -1::signed-32, 0::signed-32, 2::signed-32, 1, 0>>
  end

  test "hierarchical plans use parent-first node indices and complete sibling groups" do
    config = Config.new!(%{distance: 128, max_level: 3})
    {:ok, plan} = Plan.new({-10, 0, -10}, {-192, 319}, config)
    packet = Wire.plan(9, 0, Map.put(plan, :content, 4), config) |> IO.iodata_to_binary()

    <<"WSP1", 9::64, 4::64, 0::64, 128::16, _::32, _::32, count::16, roots::16, rest::binary>> =
      packet

    assert count == map_size(plan.nodes)
    assert roots == length(plan.roots)
    <<_root_indices::binary-size(^roots * 2), records::binary>> = rest
    indices = plan.order |> Enum.with_index() |> Map.new()

    Enum.reduce(plan.order, records, fn key, remaining ->
      {x, y, z} = key.position
      level = key.level
      children = plan.nodes[key]
      length = length(children)

      assert <<^x::signed-32, ^y::signed-32, ^z::signed-32, ^level, ^length, tail::binary>> =
               remaining

      <<child_bytes::binary-size(^length * 2), following::binary>> = tail
      assert for(<<index::16 <- child_bytes>>, do: index) == Enum.map(children, &indices[&1])
      assert Enum.all?(children, &(indices[&1] > indices[key]))
      following
    end)
    |> then(&assert(&1 == <<>>))
  end

  test "revisioned plans carry stable lineage and a bounded stamp for every node" do
    config = Config.new!(%{})
    {:ok, key} = Key.new({-1, 0, 2}, 1)

    plan = %{
      roots: [key],
      order: [key],
      nodes: %{key => []},
      content: 9,
      lineage: 7,
      revisions: %{key => 2}
    }

    assert IO.iodata_to_binary(Wire.plan(3, 5, plan, config, 3)) ==
             <<"WSP2", 3::64, 7::64, 5::64, 1024::16, 67_108_864::32, 67_108_864::32, 1::16,
               1::16, 0::16, -1::signed-32, 0::signed-32, 2::signed-32, 1, 0, 2::64>>

    for revisions <- [%{}, %{key => 6}, %{key => -1}, %{key => 2, extra: 0}] do
      assert_raise ArgumentError, fn ->
        Wire.plan(3, 5, %{plan | revisions: revisions}, config, 3)
      end
    end

    assert_raise ArgumentError, fn -> Wire.plan(3, 5, %{plan | lineage: 0}, config, 3) end
  end

  test "surface metadata has explicit cell sizes and remains bounded" do
    {:ok, key} = Key.new({-1, 0, 2}, 1)
    cell = <<3::little-16, 8::little-32, 255, 1, 9::little-16>>

    for {mode, payload} <- [{1, cell}, {2, :binary.copy(cell, 4096)}] do
      tile =
        <<"WSL2", 1, mode, 0, 0, -1::little-signed-32, 0::little-signed-32, 2::little-signed-32,
          payload::binary>>

      assert Wire.valid_tile?({key, tile})
      assert byte_size(tile) <= 40_980

      assert <<"WST1", _::64, _::64, 1::16, size::32, ^tile::binary>> =
               IO.iodata_to_binary(Wire.tiles(3, 11, [{key, tile}]))

      assert size == byte_size(tile)
      refute Wire.valid_tile?({key, tile <> <<0>>})
      refute Wire.valid_tile?({key, binary_part(tile, 0, byte_size(tile) - 1)})
    end
  end

  test "two-tile delivery has bounded explicit lengths and a numeric credit identity" do
    {:ok, key} = Key.new({-1, 0, 2}, 1)
    tile = <<"WSL1", 1, 0, 0, 0, -1::little-signed-32, 0::little-signed-32, 2::little-signed-32>>

    assert IO.iodata_to_binary(Wire.tiles(3, 11, [{key, tile}])) ==
             <<"WST1", 3::64, 11::64, 1::16, 20::32, tile::binary>>

    assert_raise ArgumentError, fn -> Wire.tiles(3, 11, List.duplicate({key, tile}, 3)) end
    assert_raise ArgumentError, fn -> Wire.tiles(3, 11, [{key, <<0>>}]) end
    assert_raise ArgumentError, fn -> Wire.tiles(3, 11, [{key, tile}, {key, tile}]) end
    assert_raise ArgumentError, fn -> Wire.tiles(0, 11, [{key, tile}]) end
  end
end
