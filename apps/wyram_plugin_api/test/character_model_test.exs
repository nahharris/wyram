defmodule Wyram.Character.ModelTest do
  use ExUnit.Case, async: true
  alias Wyram.Character.{Catalog, Definition, Model, Profile}

  test "original model import validates geometry and ordered skeleton references" do
    model = Model.fallback()
    assert :ok = Model.validate(model)
    assert Model.to_wire(model).id == "default"
    assert {:error, :invalid_character_model} = Model.validate(%{model | base_height: 0})
    [root] = model.bones

    assert {:error, :invalid_character_model} =
             Model.validate(%{model | bones: [%{root | parent: "missing"}]})

    assert {:error, :invalid_character_model} = Model.validate(%{model | bones: [root, root]})
    [box] = root.boxes
    bad = %{root | boxes: [%{box | size: [0, 1, 1]}]}
    assert {:error, :invalid_character_model} = Model.validate(%{model | bones: [bad]})
    bad = %{root | boxes: [%{box | center: [0, -4, 0]}]}
    assert {:error, :invalid_character_model} = Model.validate(%{model | bones: [bad]})
  end

  test "catalog rejects invalid roster and model substitution" do
    catalog = %{models: [Model.fallback()], definitions: [Definition.player(Profile.default())]}
    assert [%Definition{id: "player", model: "default"}] = catalog.definitions
    assert :ok = Catalog.validate(catalog.models, catalog.definitions)
    duplicate = catalog.definitions ++ catalog.definitions
    assert {:error, :invalid_character_catalog} = Catalog.validate(catalog.models, duplicate)
    missing = %{hd(catalog.definitions) | model: "missing"}
    assert {:error, :invalid_character_catalog} = Catalog.validate(catalog.models, [missing])
    assert {:error, :invalid_character_catalog} = Catalog.validate(catalog.models, [])
  end
end
