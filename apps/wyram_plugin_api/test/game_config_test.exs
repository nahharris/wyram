defmodule Wyram.GameConfigTest do
  use ExUnit.Case, async: true

  alias Wyram.Block.Ref
  alias Wyram.Character.{Catalog, Definition, Model, Profile}
  alias Wyram.Game.Config

  test "a game configuration contains logical terrain refs and validated character data" do
    profile = Profile.default()
    models = [Model.fallback()]
    characters = [Definition.player(profile, "default")]

    assert {:ok, config} =
             create(%{
               terrain: terrain(),
               profile: profile,
               models: models,
               characters: characters
             })

    assert config.terrain == terrain()
    assert config.profile == profile
    assert config.models == models
    assert config.characters == characters
  end

  test "missing or forged terrain refs cannot enter compiled game configuration" do
    assert {:error, :invalid_terrain} = create(%{terrain: %{}})

    assert {:error, :invalid_terrain} =
             create(%{terrain: Map.put(terrain(), :surface, "game:grass")})

    assert {:error, :invalid_terrain} =
             create(%{
               terrain: Map.put(terrain(), :soil, %Ref{plugin_id: "game", local_id: "bad:id"})
             })
  end

  test "profile and character failures are rejected during configuration construction" do
    assert {:error, :invalid_character_profile} =
             create(%{terrain: terrain(), profile: %{Profile.default() | gravity: -1}})

    assert {:error, :invalid_character_catalog} =
             create(%{terrain: terrain(), models: []})

    assert {:error, :invalid_character_catalog} =
             create(%{terrain: terrain(), characters: []})
  end

  test "configuration fields are checked and defaults are complete public data" do
    assert {:error, :unknown_game_field} =
             create(%{terrain: terrain(), profille: Profile.default()})

    assert {:ok, config} = create(%{terrain: terrain()})
    assert config.profile == Profile.default()
    assert :ok == Catalog.validate(config.models, config.characters)
  end

  test "bang and validation APIs reject forged profiles instead of accepting extra fields" do
    profile = Map.put(Profile.default(), :unknown_tuning, 1)

    assert_raise ArgumentError, fn ->
      Config.new!(%{terrain: terrain(), profile: profile})
    end

    {:ok, valid} = create(%{terrain: terrain()})

    assert {:error, :invalid_character_profile} =
             Config.validate(Map.put(valid, :profile, profile))
  end

  test "malformed character structs produce validation errors instead of key errors" do
    profile = Map.delete(Profile.default(), :gravity)
    assert {:error, :invalid_character_profile} = create(%{terrain: terrain(), profile: profile})

    model = Map.delete(Model.fallback(), :id)
    assert {:error, :invalid_character_catalog} = create(%{terrain: terrain(), models: [model]})
  end

  test "nested model bones and boxes reject unknown fields" do
    model = Model.fallback()
    [bone] = model.bones

    extended_bone = Map.put(bone, :unvalidated_extension, :accepted)
    extended_bone_model = %{model | bones: [extended_bone]}

    assert {:error, :invalid_character_catalog} =
             create(%{terrain: terrain(), models: [extended_bone_model]})

    [box] = bone.boxes
    extended_box = Map.put(box, :unvalidated_extension, :accepted)

    assert {:error, :invalid_character_catalog} =
             create(%{
               terrain: terrain(),
               models: [%{model | bones: [%{bone | boxes: [extended_box]}]}]
             })

    {:ok, valid_config} = create(%{terrain: terrain()})

    assert {:error, :invalid_character_catalog} =
             Config.validate(%{valid_config | models: [extended_bone_model]})
  end

  test "character definitions reject malformed nested profiles" do
    profile = Map.put(Profile.default(), :unvalidated_extension, :accepted)
    character = Definition.player(profile)

    assert {:error, :invalid_character_catalog} =
             create(%{terrain: terrain(), characters: [character]})
  end

  defp terrain do
    %{
      surface: Ref.new!("game", "grass"),
      soil: Ref.new!("game", "dirt"),
      rock: Ref.new!("game", "stone")
    }
  end

  defp create(attrs), do: Config.new(attrs)
end
