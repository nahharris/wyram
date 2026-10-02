defmodule Wyram.Game.Config do
  @moduledoc "Validated game setup data compiled into a plugin catalog."

  alias Wyram.Block.Ref
  alias Wyram.Character.{Catalog, Definition, Model, Profile}

  @enforce_keys [:terrain, :profile, :models, :characters]
  defstruct [:terrain, :profile, :models, :characters]

  @type terrain :: %{surface: Ref.t(), soil: Ref.t(), rock: Ref.t()}
  @type t :: %__MODULE__{
          terrain: terrain(),
          profile: Profile.t(),
          models: [Model.t()],
          characters: [Definition.t()]
        }

  @fields [:terrain, :profile, :models, :characters]
  @bone_fields [:name, :parent, :role, :pivot, :boxes]
  @box_fields [:center, :size, :color]

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    terrain = Map.get(attrs, :terrain)
    profile = Map.get(attrs, :profile, Profile.default())
    models = Map.get(attrs, :models, [Model.fallback()])

    with :ok <- known_fields(attrs),
         :ok <- valid_terrain(terrain),
         :ok <- valid_profile(profile),
         characters =
           Map.get_lazy(attrs, :characters, fn -> default_characters(models, profile) end),
         :ok <- valid_catalog(models, characters) do
      {:ok,
       %__MODULE__{terrain: terrain, profile: profile, models: models, characters: characters}}
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
    with {:ok, _config} <- new(Map.from_struct(config)), do: :ok
  end

  def validate(_), do: {:error, :invalid_game_config}

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

  defp valid_terrain(terrain) when is_map(terrain) do
    if Enum.sort(Map.keys(terrain)) == Enum.sort([:surface, :soil, :rock]) and
         Enum.all?(Map.values(terrain), &valid_ref?/1),
       do: :ok,
       else: {:error, :invalid_terrain}
  end

  defp valid_terrain(_), do: {:error, :invalid_terrain}

  defp valid_ref?(%Ref{plugin_id: plugin_id, local_id: local_id} = ref) do
    Map.keys(ref) |> Enum.sort() == [:__struct__, :local_id, :plugin_id] and
      match?({:ok, _}, Ref.new(plugin_id, local_id))
  end

  defp valid_ref?(_), do: false

  defp default_characters([%Model{id: id} | _], profile),
    do: [Definition.player(profile, id)]

  defp default_characters(_, _), do: []
end

defmodule Wyram.Game.Provider do
  @moduledoc """
  Public build contract for game setup.

  The plugin compiler invokes explicitly declared providers and validates their
  output. The engine consumes compiled configuration data instead of callbacks.
  """

  @callback build() :: Wyram.Game.Config.t()
end
