defmodule Wyram.Engine.LodWorkersTest do
  use ExUnit.Case, async: true

  alias Wyram.Engine.LodWorkers

  test "worker overrides parse only whole integers in the supported range" do
    env = %{"WYRAM_LOD_GEN_WORKERS" => "8", "WYRAM_LOD_MESH_WORKERS" => "2"}
    assert LodWorkers.overrides(&Map.get(env, &1)) == %{generation: 8, meshing: 2}

    assert LodWorkers.overrides(fn _ -> nil end) == %{generation: nil, meshing: nil}

    for value <- ["", " ", "0", "9", "2.5", "3tail"] do
      assert_raise ArgumentError, ~r/WYRAM_LOD_GEN_WORKERS/, fn ->
        LodWorkers.overrides(fn
          "WYRAM_LOD_GEN_WORKERS" -> value
          _ -> nil
        end)
      end

      assert_raise ArgumentError, ~r/WYRAM_LOD_MESH_WORKERS/, fn ->
        LodWorkers.overrides(fn
          "WYRAM_LOD_MESH_WORKERS" -> value
          _ -> nil
        end)
      end
    end
  end

  test "detected parallelism requires both positive measurements" do
    assert LodWorkers.resolve(22, 22) == %{
             parallelism: 22,
             budget: 8,
             generation: 4,
             meshing: 4
           }

    assert LodWorkers.resolve(22, 16) == %{
             parallelism: 16,
             budget: 6,
             generation: 3,
             meshing: 3
           }

    assert LodWorkers.resolve(nil, 22).parallelism == 4
    assert LodWorkers.resolve(22, nil).parallelism == 4
    assert LodWorkers.resolve(0, 22).parallelism == 4

    assert LodWorkers.resolve(nil, nil) == %{
             parallelism: 4,
             budget: 2,
             generation: 1,
             meshing: 1
           }
  end

  test "odd budgets split with generation receiving the extra worker" do
    assert LodWorkers.resolve(18, 18) == %{
             parallelism: 18,
             budget: 7,
             generation: 4,
             meshing: 3
           }
  end

  test "overrides independently replace role counts without changing the total budget" do
    assert LodWorkers.resolve(4, 4, %{generation: 8, meshing: 2}) == %{
             parallelism: 4,
             budget: 2,
             generation: 8,
             meshing: 2
           }

    assert LodWorkers.resolve(22, 22, %{generation: nil, meshing: 6}) == %{
             parallelism: 22,
             budget: 8,
             generation: 4,
             meshing: 6
           }

    assert_raise ArgumentError, fn ->
      LodWorkers.resolve(4, 4, %{generation: 0, meshing: nil})
    end
  end
end
