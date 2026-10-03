defmodule Wyram.Plugin.Content do
  @moduledoc "Data-only validation of compiled content and its typed reference bindings."
  alias Wyram.Block.Ref
  alias Wyram.Character.{Definition, Model, Profile}
  alias Wyram.Plugin.{Kind, ModuleName}
  alias Wyram.WorldGen.{Biome, Config, Schema, Terrain}

  @record_fields [:data, :id, :kind, :local_id, :module, :plugin_id, :references]
  @reference_fields [:id, :kind, :module, :plugin_id]

  def valid_records?(records, plugin_id, modules)
      when is_list(records) and length(records) <= 4096 do
    Enum.all?(
      records,
      &(valid_record?(&1) and &1.plugin_id == plugin_id and &1.module in modules)
    ) and
      length(Enum.uniq_by(records, &{&1.kind, &1.id})) == length(records) and
      length(Enum.uniq_by(records, & &1.module)) == length(records)
  rescue
    _ -> false
  end

  def valid_records?(_records, _plugin_id, _modules), do: false

  def valid_record?(record) when is_map(record) do
    Enum.sort(Map.keys(record)) == @record_fields and
      valid_identity?(record) and
      record.kind in (Kind.kinds() -- [:block]) and
      valid_data?(record.kind, record.data, record.id) and valid_references?(record.references)
  rescue
    _ -> false
  end

  def valid_record?(_record), do: false

  defp valid_identity?(record) do
    Ref.valid_plugin_id?(record.plugin_id) and Ref.valid_local_id?(record.local_id) and
      record.id == record.plugin_id <> ":" <> record.local_id and
      ModuleName.valid_string?(record.module)
  end

  defp valid_references?(references) do
    is_list(references) and length(references) <= 256 and
      Enum.all?(references, &valid_reference?/1) and Enum.uniq(references) == references
  end

  def links_valid?(record, index, allowed_plugins) do
    references =
      Enum.map(record.references, fn reference ->
        target = Map.get(index, {reference.kind, reference.id})

        if is_nil(target) or target.module != reference.module or
             target.plugin_id != reference.plugin_id or
             reference.plugin_id not in allowed_plugins,
           do: throw(:invalid_content_link)

        target
      end)

    bindings_valid?(record.kind, record.data, references)
  catch
    :invalid_content_link -> false
  end

  defp valid_reference?(reference) when is_map(reference) do
    Enum.sort(Map.keys(reference)) == @reference_fields and reference.kind in Kind.kinds() and
      Ref.valid_plugin_id?(reference.plugin_id) and ModuleName.valid_string?(reference.module) and
      is_binary(reference.id) and String.starts_with?(reference.id, reference.plugin_id <> ":") and
      Ref.valid_local_id?(String.replace_prefix(reference.id, reference.plugin_id <> ":", ""))
  end

  defp valid_reference?(_reference), do: false

  defp valid_data?(:profile, data, _id),
    do: Schema.complete?(data, Profile) and Profile.validate(data) == :ok

  defp valid_data?(:shaping, data, _id), do: Terrain.validate(data) == :ok
  defp valid_data?(:biome, data, id), do: Biome.validate(data) == :ok and data.id == id
  defp valid_data?(:worldgen, data, _id), do: Config.validate(data) == :ok

  defp valid_data?(:model, data, id),
    do:
      Schema.complete?(data, Model) and Model.validate(data) == :ok and data.id == id and
        model_fields?(data)

  defp valid_data?(:character, data, id),
    do:
      Schema.complete?(data, Definition) and Definition.valid?(data) and
        Schema.complete?(data.profile, Profile) and data.id == id

  defp valid_data?(_kind, _data, _id), do: false

  defp model_fields?(data) do
    Enum.all?(data.bones, fn bone ->
      fields?(bone, [:boxes, :name, :parent, :pivot, :role]) and
        Enum.all?(bone.boxes, &fields?(&1, [:center, :color, :size]))
    end)
  end

  defp fields?(value, fields) when is_map(value), do: Enum.sort(Map.keys(value)) == fields
  defp fields?(_value, _fields), do: false

  defp bindings_valid?(kind, _data, references) when kind in [:profile, :model, :shaping],
    do: references == []

  defp bindings_valid?(:biome, data, references) do
    Enum.all?(references, &(&1.kind == :block)) and
      MapSet.new(Enum.map(references, & &1.id)) ==
        MapSet.new(Enum.map(Biome.references(data), &Ref.canonical_id/1))
  end

  defp bindings_valid?(:character, data, references) do
    case Enum.sort_by(references, & &1.kind) do
      [%{kind: :model, data: model}, %{kind: :profile, data: profile}] ->
        data.model == model.id and data.profile == profile

      _ ->
        false
    end
  end

  defp bindings_valid?(:worldgen, data, references) do
    biomes = Enum.filter(references, &(&1.kind == :biome)) |> Enum.map(& &1.data)
    shaping = Enum.filter(references, &(&1.kind == :shaping))

    Enum.all?(references, &(&1.kind in [:biome, :shaping])) and
      Enum.sort_by(biomes, & &1.id) == Enum.sort_by(data.biomes, & &1.id) and
      (shaping == [] or match?([%{data: value}] when value == data.terrain, shaping))
  end
end
