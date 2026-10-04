defmodule Wyram.GameConfigTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Character.{Catalog, Definition, Model, Profile}
  alias Wyram.Game.Config
  alias Wyram.WorldGen.Biome
  alias Wyram.WorldGen.Config, as: WorldGenConfig

  test "scenery is optional public policy and requires a shared world generator" do
    ref = Ref.new!("game", "grass")

    worldgen =
      WorldGenConfig.new!(%{
        biomes: [Biome.new!(%{id: "test", surface: ref, soil: ref, rock: ref})]
      })

    scenery = %Wyram.Scenery.Config{}
    assert {:ok, config} = Config.new(%{worldgen: worldgen, scenery: scenery})
    assert config.scenery == scenery
    assert :ok = Config.validate(config)
    assert {:ok, plain} = Config.new(%{worldgen: worldgen})
    assert plain.scenery == nil

    assert Config.new(%{palette: palette(), scenery: scenery}) ==
             {:error, :scenery_requires_worldgen}

    assert Config.new(%{worldgen: worldgen, scenery: %{scenery | workers: 3}}) ==
             {:error, :invalid_scenery_config}
  end

  test "generation has one source of truth and a worldgen game needs no fallback palette" do
    ref = Ref.new!("game", "grass")
    biome = Biome.new!(%{id: "game:woodland", surface: ref, soil: ref, rock: ref})
    worldgen = WorldGenConfig.new!(%{biomes: [biome]})
    assert {:ok, config} = Config.new(%{worldgen: worldgen})
    assert is_nil(config.palette)
    assert Config.references(config) == WorldGenConfig.references(worldgen)
    assert {:error, :ambiguous_generation} = Config.new(%{worldgen: worldgen, palette: palette()})
    assert {:error, :missing_generation} = Config.new(%{})
  end

  test "a game configuration contains logical palette refs and validated character data" do
    profile = Profile.default()
    models = [Model.fallback()]
    characters = [Definition.player(profile, "default")]

    assert {:ok, config} =
             create(%{
               palette: palette(),
               profile: profile,
               models: models,
               characters: characters
             })

    assert config.palette == palette()
    assert config.profile == profile
    assert config.models == models
    assert config.characters == characters
  end

  test "missing or forged palette refs cannot enter compiled game configuration" do
    assert {:error, :invalid_palette} = create(%{palette: %{}})

    assert {:error, :invalid_palette} =
             create(%{palette: Map.put(palette(), :surface, "game:grass")})

    assert {:error, :invalid_palette} =
             create(%{
               palette: Map.put(palette(), :soil, %Ref{plugin_id: "game", local_id: "bad:id"})
             })
  end

  test "profile and character failures are rejected during configuration construction" do
    assert {:error, :invalid_character_profile} =
             create(%{palette: palette(), profile: %{Profile.default() | gravity: -1}})

    assert {:error, :invalid_character_catalog} =
             create(%{palette: palette(), models: []})

    assert {:error, :invalid_character_catalog} =
             create(%{palette: palette(), characters: []})
  end

  test "configuration fields are checked and defaults are complete public data" do
    assert {:error, :unknown_game_field} =
             create(%{palette: palette(), profille: Profile.default()})

    assert {:ok, config} = create(%{palette: palette()})
    assert config.profile == Profile.default()
    assert :ok == Catalog.validate(config.models, config.characters)
  end

  test "bang and validation APIs reject forged profiles instead of accepting extra fields" do
    profile = Map.put(Profile.default(), :unknown_tuning, 1)

    assert_raise ArgumentError, fn ->
      Config.new!(%{palette: palette(), profile: profile})
    end

    {:ok, valid} = create(%{palette: palette()})

    assert {:error, :invalid_character_profile} =
             Config.validate(Map.put(valid, :profile, profile))
  end

  test "malformed character structs produce validation errors instead of key errors" do
    profile = Map.delete(Profile.default(), :gravity)
    assert {:error, :invalid_character_profile} = create(%{palette: palette(), profile: profile})

    model = Map.delete(Model.fallback(), :id)
    assert {:error, :invalid_character_catalog} = create(%{palette: palette(), models: [model]})
  end

  test "nested model bones and boxes reject unknown fields" do
    model = Model.fallback()
    [bone] = model.bones

    extended_bone = Map.put(bone, :unvalidated_extension, :accepted)
    extended_bone_model = %{model | bones: [extended_bone]}

    assert {:error, :invalid_character_catalog} =
             create(%{palette: palette(), models: [extended_bone_model]})

    [box] = bone.boxes
    extended_box = Map.put(box, :unvalidated_extension, :accepted)

    assert {:error, :invalid_character_catalog} =
             create(%{
               palette: palette(),
               models: [%{model | bones: [%{bone | boxes: [extended_box]}]}]
             })

    {:ok, valid_config} = create(%{palette: palette()})

    assert {:error, :invalid_character_catalog} =
             Config.validate(%{valid_config | models: [extended_bone_model]})
  end

  test "character definitions reject malformed nested profiles" do
    profile = Map.put(Profile.default(), :unvalidated_extension, :accepted)
    character = Definition.player(profile)

    assert {:error, :invalid_character_catalog} =
             create(%{palette: palette(), characters: [character]})
  end

  defp palette do
    %{
      surface: Ref.new!("game", "grass"),
      soil: Ref.new!("game", "dirt"),
      rock: Ref.new!("game", "stone")
    }
  end

  defp create(attrs), do: Config.new(attrs)
end
