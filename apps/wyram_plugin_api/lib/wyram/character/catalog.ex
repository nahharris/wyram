defmodule Wyram.Character.Catalog do
  @moduledoc "Load bounded original rigs and character definitions from the selected game plugin."
  alias Wyram.Character.{Definition, Model}

  def from_plugin(module, profile) do
    models =
      if function_exported?(module, :character_models, 0),
        do: module.character_models(),
        else: [Model.fallback()]

    definitions =
      if function_exported?(module, :characters, 0),
        do: module.characters(),
        else: [Definition.player(profile, first_model(models))]

    with :ok <- validate(models, definitions),
         do: {:ok, %{models: models, definitions: definitions}}
  end

  defp first_model([%Model{id: id} | _]), do: id
  defp first_model(_), do: "default"

  def validate(models, definitions) do
    valid =
      bounded?(models) and bounded?(definitions) and
        Enum.all?(models, &(Model.validate(&1) == :ok)) and
        Enum.all?(definitions, &Definition.valid?/1)

    if valid and bindings?(models, definitions),
      do: :ok,
      else: {:error, :invalid_character_catalog}
  end

  defp bounded?(list), do: is_list(list) and length(list) in 1..16

  defp bindings?(models, definitions) do
    model_ids = Enum.map(models, & &1.id)
    ids = Enum.map(definitions, & &1.id)

    length(Enum.uniq(model_ids)) == length(model_ids) and length(Enum.uniq(ids)) == length(ids) and
      "player" in ids and Enum.all?(definitions, &(&1.model in model_ids))
  end
end
