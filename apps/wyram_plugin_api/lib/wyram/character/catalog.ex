defmodule Wyram.Character.Catalog do
  @moduledoc "Validate bounded original rigs and character definitions in compiled game configuration."
  alias Wyram.Character.{Definition, Model}

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
