defmodule Wyram.WorldGenDslTest do
  use ExUnit.Case, async: true
  alias Wyram.WorldGen.Biome

  test "defbiome produces named public data constructors and an ordered catalog" do
    module = Module.concat(__MODULE__, "Biomes#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Wyram.WorldGen
      alias Wyram.Block.Ref
      defbiome Coast do
        %{id: "game:coast", climate: %{humidity: 0.75}, surface: Ref.new!("game","grass"), soil: Ref.new!("game","dirt"), rock: Ref.new!("game","stone")}
      end
      defbiome Upland do
        %{id: "game:upland", climate: %{elevation: 0.8}, surface: Ref.new!("game","stone"), soil: Ref.new!("game","stone"), rock: Ref.new!("game","stone")}
      end
    end
    """)

    biomes = module.biomes()
    assert Enum.map(biomes, & &1.id) == ["game:coast", "game:upland"]
    assert :ok == Biome.validate(hd(biomes))
    assert Module.concat(module, Coast).biome() == hd(biomes)
  end

  test "duplicate declarations fail before a constructor can be replaced" do
    module = Module.concat(__MODULE__, "Duplicate#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/duplicate biome declaration/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Wyram.WorldGen
        defbiome Wilds do
          %{}
        end
        defbiome Wilds do
          %{}
        end
      end
      """)
    end
  end

  test "declarations validate their data when the game builder collects it" do
    module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Wyram.WorldGen
      defbiome Invalid do
        %{id: "invalid", runtime_callback: fn -> :terrain end}
      end
    end
    """)

    assert_raise ArgumentError, fn -> module.biomes() end
  end
end
