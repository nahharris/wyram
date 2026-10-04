defmodule Wyram.Scenery.ConfigTest do
  use ExUnit.Case, async: true
  alias Wyram.Scenery.Config

  test "default and explicit policies bound resolution, residency and worker concurrency" do
    assert {:ok, default} = Config.new(%{})
    assert default.distance == 1024
    assert default.workers == 2
    assert :ok = Config.validate(default)
    assert {:ok, explicit} = Config.new(%{distance: 2048, max_level: 6, workers: 1})
    assert explicit.distance == 2048
    assert explicit.max_level == 6
    assert explicit.workers == 1

    assert Config.new(%{max_tiles: 1024, cache_bytes: 32_788 * 1024}) ==
             {:error, :invalid_scenery_config}

    assert {:ok, _} = Config.new(%{max_tiles: 1024, cache_bytes: 40_980 * 1024})
  end

  test "invalid, forged and unknown policy data cannot enter a game catalog" do
    for attrs <- [
          nil,
          [],
          %{unknown: 1},
          %{distance: 0},
          %{distance: 1025},
          %{distance: 8192},
          %{max_level: 0},
          %{max_level: 7},
          %{max_level: 1.0},
          %{detail_distance: 0},
          %{max_tiles: 0},
          %{max_tiles: 8192},
          %{workers: 0},
          %{workers: 3},
          %{cache_bytes: 0},
          %{mesh_bytes: 0}
        ] do
      assert Config.new(attrs) == {:error, :invalid_scenery_config}
    end

    assert Config.validate(Map.put(%Config{}, :unknown, true)) ==
             {:error, :invalid_scenery_config}

    assert Config.validate(Map.delete(%Config{}, :workers)) == {:error, :invalid_scenery_config}
    replaced = %Config{} |> Map.delete(:workers) |> Map.put(:unknown, 1)
    assert Config.validate(replaced) == {:error, :invalid_scenery_config}
    assert Config.validate(Map.from_struct(%Config{})) == {:error, :invalid_scenery_config}
  end
end
