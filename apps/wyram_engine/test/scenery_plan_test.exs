defmodule Wyram.Engine.Scenery.PlanTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.Plan
  alias Wyram.Scenery.{Config, Key}

  test "the full-detail interior does not consume distant refinement nodes" do
    assert {:ok, plan} = Plan.new({8, 8, 8}, {-192, 319}, Config.new!(%{}))
    key = %Key{position: {0, 0, 0}, level: 2}
    assert Map.has_key?(plan.nodes, key)
    assert plan.nodes[key] == []
    assert Enum.any?(plan.nodes, fn {tile, _} -> tile.level == 1 end)
  end

  test "mesh reserves limit refinements and reject roots that cannot retain complete coverage" do
    config =
      Config.new!(%{max_tiles: 4096, cache_bytes: 256 * 1024 * 1024, mesh_bytes: 4 * 1024 * 1024})

    assert {:ok, plan} = Plan.new({0, 0, 0}, {-192, 319}, config)
    assert map_size(plan.nodes) * 2592 <= config.mesh_bytes
    config = %{config | distance: 4096, max_level: 3}
    assert Plan.new({0, 0, 0}, {-192, 319}, config) == {:error, :scenery_root_budget}
  end

  test "refinement stays bounded and every replacement is a complete ordered sibling set" do
    config = Config.new!(%{})
    assert {:ok, plan} = Plan.new({-17, 260, -33}, {-192, 319}, config)
    assert map_size(plan.nodes) <= config.max_tiles
    assert plan.roots != []
    assert MapSet.new(plan.order) == MapSet.new(Map.keys(plan.nodes))
    assert length(plan.order) == map_size(plan.nodes)
    positions = plan.order |> Enum.with_index() |> Map.new()

    for {key, children} <- plan.nodes do
      assert :ok = Key.validate(key)
      assert key.level in 1..config.max_level
      assert length(children) in [0, 8]

      if children != [] do
        assert length(Enum.uniq(children)) == 8
        assert Enum.map(children, &Key.parent/1) == List.duplicate({:ok, key}, 8)
        assert Enum.all?(children, &Map.has_key?(plan.nodes, &1))
        assert Enum.all?(children, &(positions[&1] > positions[key]))
      end
    end

    assert Enum.any?(plan.nodes, fn {key, _} -> key.level == 1 end)
    assert Enum.all?(plan.roots, &(&1.level == config.max_level))
    assert plan == elem(Plan.new({-17, 260, -33}, {-192, 319}, config), 1)
  end

  test "roots cover the view and world height without overlapping one another" do
    observer = {-17, 260, -33}
    assert {:ok, plan} = Plan.new(observer, {-192, 319}, Config.new!(%{}))

    for dx <- [-1024, -1, 0, 1024], dz <- [-1024, 0, 1024], y <- [-192, 0, 319] do
      point = {elem(observer, 0) + dx, y, elem(observer, 2) + dz}
      assert Enum.count(plan.roots, &contains?(&1, point)) == 1
    end
  end

  test "a tight node budget retains coarse coverage and invalid plans return errors" do
    assert {:ok, config} = Config.new(%{max_tiles: 64})
    assert {:ok, plan} = Plan.new({0, 0, 0}, {-192, 319}, config)
    assert map_size(plan.nodes) <= 64
    assert length(plan.roots) == 50
    for {_, children} <- plan.nodes, do: assert(length(children) in [0, 8])
    undersized = Config.new!(%{max_level: 1, max_tiles: 64})
    assert Plan.new({0, 0, 0}, {-192, 319}, undersized) == {:error, :scenery_root_budget}
    assert Plan.new({0, 0, 0}, {320, -192}, config) == {:error, :invalid_scenery_view}
    assert Plan.new({0.5, 0, 0}, {-192, 319}, config) == {:error, :invalid_scenery_view}

    assert Plan.new({0, 0, 0}, {-192, 319}, %{config | workers: 3}) ==
             {:error, :invalid_scenery_view}

    assert Plan.new({2_147_483_647, 0, 0}, {-192, 319}, config) == {:error, :invalid_scenery_view}
    assert {:ok, edge} = Plan.new({999_900, 100, -999_900}, {-192, 319}, config)

    for key <- Map.keys(edge.nodes) do
      {:ok, origin} = Key.origin(key)
      width = 16 * Integer.pow(2, key.level)
      assert Enum.all?(Tuple.to_list(origin), &(&1 >= -1_000_000 and &1 + width - 1 <= 1_000_000))
    end
  end

  defp contains?(key, point) do
    {:ok, origin} = Key.origin(key)
    width = 16 * Integer.pow(2, key.level)

    Enum.zip(Tuple.to_list(origin), Tuple.to_list(point))
    |> Enum.all?(fn {low, value} -> value in low..(low + width - 1) end)
  end
end
