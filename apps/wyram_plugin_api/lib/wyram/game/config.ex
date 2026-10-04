defmodule Wyram.Game.Config do
  @moduledoc "Validated game setup data compiled into a plugin catalog."

  alias Wyram.Block.Ref
  alias Wyram.Character.{Catalog, Definition, Model, Profile}

  alias Wyram.WorldGen.Config, as: WorldGenConfig

  @enforce_keys [:profile, :models, :characters]
  defstruct [
    :profile,
    :models,
    :characters,
    palette: nil,
    worldgen: nil,
    scenery: nil,
    spawn: :configured
  ]

  @type palette :: %{surface: Ref.t(), soil: Ref.t(), rock: Ref.t()}
  @type t :: %__MODULE__{
          palette: palette() | nil,
          profile: Profile.t(),
          models: [Model.t()],
          characters: [Definition.t()],
          worldgen: WorldGenConfig.t() | nil,
          scenery: Wyram.Scenery.Config.t() | nil,
          spawn: :configured | :surface
        }

  @fields [:palette, :profile, :models, :characters, :worldgen, :scenery, :spawn]
  @bone_fields [:name, :parent, :role, :pivot, :boxes]
  @box_fields [:center, :size, :color]

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    palette = Map.get(attrs, :palette)
    profile = Map.get(attrs, :profile, Profile.default())
    models = Map.get(attrs, :models, [Model.fallback()])

    with :ok <- known_fields(attrs),
         :ok <- valid_generation(palette, Map.get(attrs, :worldgen)),
         :ok <- valid_profile(profile),
         :ok <- valid_worldgen(Map.get(attrs, :worldgen)),
         :ok <- valid_scenery(Map.get(attrs, :scenery), Map.get(attrs, :worldgen)),
         :ok <- valid_spawn(Map.get(attrs, :spawn, :configured)),
         characters =
           Map.get_lazy(attrs, :characters, fn -> default_characters(models, profile) end),
         :ok <- valid_catalog(models, characters) do
      {:ok,
       %__MODULE__{
         palette: palette,
         profile: profile,
         models: models,
         characters: characters,
         worldgen: Map.get(attrs, :worldgen),
         scenery: Map.get(attrs, :scenery),
         spawn: Map.get(attrs, :spawn, :configured)
       }}
    end
  end

  def new(_), do: {:error, :invalid_game_config}

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid game configuration: #{reason}"
    end
  end

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = config) do
    if complete_struct?(config, __MODULE__) do
      with {:ok, _config} <- new(Map.from_struct(config)), do: :ok
    else
      {:error, :invalid_game_config}
    end
  end

  def validate(_), do: {:error, :invalid_game_config}

  def references(config),
    do: palette_references(config.palette) ++ worldgen_references(config.worldgen)

  defp palette_references(nil), do: []
  defp palette_references(palette), do: Map.values(palette)
  defp worldgen_references(nil), do: []
  defp worldgen_references(value), do: WorldGenConfig.references(value)
  defp valid_spawn(policy) when policy in [:configured, :surface], do: :ok
  defp valid_spawn(_), do: {:error, :invalid_spawn_policy}
  defp valid_worldgen(nil), do: :ok
  defp valid_worldgen(value), do: WorldGenConfig.validate(value)
  defp valid_scenery(nil, _), do: :ok
  defp valid_scenery(_, nil), do: {:error, :scenery_requires_worldgen}
  defp valid_scenery(value, _), do: Wyram.Scenery.Config.validate(value)

  defp valid_profile(profile) do
    if complete_struct?(profile, Profile),
      do: Profile.validate(profile),
      else: {:error, :invalid_character_profile}
  end

  defp valid_catalog(models, characters) do
    if bounded_structs?(models, Model) and bounded_structs?(characters, Definition) and
         Enum.all?(models, &complete_model_maps?/1) and
         Enum.all?(characters, &(valid_profile(&1.profile) == :ok)),
       do: Catalog.validate(models, characters),
       else: {:error, :invalid_character_catalog}
  end

  defp complete_model_maps?(%Model{bones: bones}) when is_list(bones) do
    Enum.all?(bones, fn bone ->
      with true <- exact_map_fields?(bone, @bone_fields),
           boxes when is_list(boxes) <- Map.get(bone, :boxes) do
        Enum.all?(boxes, &exact_map_fields?(&1, @box_fields))
      else
        _ -> false
      end
    end)
  end

  defp complete_model_maps?(_), do: false

  defp exact_map_fields?(value, fields) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp exact_map_fields?(_, _), do: false

  defp bounded_structs?(values, module) do
    is_list(values) and length(values) in 1..16 and
      Enum.all?(values, &complete_struct?(&1, module))
  end

  defp complete_struct?(value, module) when is_map(value) do
    Map.get(value, :__struct__) == module and
      Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(module.__struct__()))
  end

  defp complete_struct?(_, _), do: false

  defp known_fields(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)),
      do: :ok,
      else: {:error, :unknown_game_field}
  end

  defp valid_generation(nil, nil), do: {:error, :missing_generation}
  defp valid_generation(palette, nil), do: valid_palette(palette)
  defp valid_generation(nil, _worldgen), do: :ok
  defp valid_generation(_palette, _worldgen), do: {:error, :ambiguous_generation}

  defp valid_palette(palette) when is_map(palette) do
    if Enum.sort(Map.keys(palette)) == Enum.sort([:surface, :soil, :rock]) and
         Enum.all?(Map.values(palette), &valid_ref?/1),
       do: :ok,
       else: {:error, :invalid_palette}
  end

  defp valid_palette(_), do: {:error, :invalid_palette}

  defp valid_ref?(%Ref{plugin_id: plugin_id, local_id: local_id} = ref) do
    Map.keys(ref) |> Enum.sort() == [:__struct__, :local_id, :plugin_id] and
      match?({:ok, _}, Ref.new(plugin_id, local_id))
  end

  defp valid_ref?(_), do: false

  defp default_characters([%Model{id: id} | _], profile),
    do: [Definition.player(profile, id)]

  defp default_characters(_, _), do: []
end
