defmodule Wyram.Character.Model do
  @moduledoc "Original editable cuboid rigs: feet-space units, ordered bones and semantic roles."
  defstruct id: "default", base_height: 1.8, bones: [], attachments: %{}, capabilities: []

  @type t :: %__MODULE__{
          id: String.t(),
          base_height: number(),
          bones: [map()],
          attachments: map(),
          capabilities: [String.t()]
        }

  def fallback do
    %__MODULE__{
      bones: [
        %{
          name: "root",
          parent: nil,
          role: "root",
          pivot: [0.0, 0.0, 0.0],
          boxes: [%{center: [0.0, 0.9, 0.0], size: [0.5, 1.8, 0.3], color: [180, 160, 120]}]
        }
      ]
    }
  end

  def to_wire(model), do: Map.from_struct(model)
  def compatible?(left, right), do: roles(left) == roles(right)

  defp roles(model),
    do: model.bones |> Enum.map(& &1.role) |> Enum.reject(&(&1 == "")) |> MapSet.new()

  def validate(%__MODULE__{} = model) do
    with true <- label?(model.id),
         true <-
           is_number(model.base_height) and model.base_height >= 0.1 and model.base_height <= 8,
         true <- is_list(model.bones) and length(model.bones) in 1..32,
         {:ok, positions, bounds} <- skeleton(model.bones),
         true <-
           unique_roles?(model.bones) and Enum.sum(Enum.map(model.bones, &length(&1.boxes))) <= 64,
         true <- valid_bounds?(bounds, model.base_height),
         true <- attachments?(model.attachments, positions),
         true <-
           is_list(model.capabilities) and length(model.capabilities) <= 16 and
             Enum.all?(model.capabilities, &label?/1) do
      :ok
    else
      _ -> {:error, :invalid_character_model}
    end
  end

  def validate(_), do: {:error, :invalid_character_model}

  defp skeleton(bones) do
    Enum.reduce_while(bones, {:ok, %{}, []}, fn bone, {:ok, positions, bounds} ->
      case bone(bone, positions) do
        :ok ->
          origin = add(Map.get(positions, bone.parent, [0, 0, 0]), bone.pivot)
          boxes = Enum.flat_map(bone.boxes, &box_bounds(&1, origin))
          {:cont, {:ok, Map.put(positions, bone.name, origin), boxes ++ bounds}}

        _ ->
          {:halt, {:error, :invalid_bone}}
      end
    end)
  end

  defp bone(%{name: name, parent: parent, role: role, pivot: pivot, boxes: boxes}, positions) do
    valid =
      bone_identity?(name, parent, role, positions) and vector?(pivot, -8, 8) and is_list(boxes) and
        length(boxes) <= 8

    if valid and Enum.all?(boxes, &box?/1), do: :ok, else: {:error, :invalid_bone}
  end

  defp bone(_, _), do: {:error, :invalid_bone}
  defp parent?(nil, positions), do: map_size(positions) == 0
  defp parent?(name, positions), do: Map.has_key?(positions, name)

  defp box?(%{center: center, size: size, color: color}),
    do: vector?(center, -8, 8) and positive_vector?(size) and color?(color)

  defp box?(_), do: false
  defp positive_vector?([x, y, z] = v), do: vector?(v, 0, 8) and x > 0 and y > 0 and z > 0
  defp positive_vector?(_), do: false
  defp color?([r, g, b]), do: Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255))
  defp color?(_), do: false

  defp vector?([x, y, z], low, high),
    do: Enum.all?([x, y, z], &(is_number(&1) and &1 >= low and &1 <= high))

  defp vector?(_, _, _), do: false
  defp label?(value), do: is_binary(value) and byte_size(value) in 1..64 and String.valid?(value)
  defp add(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  defp box_bounds(box, origin) do
    center = add(origin, box.center)
    low = Enum.zip_with(center, box.size, &(&1 - &2 / 2))
    high = Enum.zip_with(center, box.size, &(&1 + &2 / 2))
    [low, high]
  end

  defp valid_bounds?([], _), do: false

  defp valid_bounds?(bounds, height),
    do:
      Enum.all?(bounds, fn [x, y, z] ->
        abs(x) <= 8 and y >= -1.0e-8 and y <= height + 1.0e-8 and abs(z) <= 8
      end)

  defp attachments?(attachments, positions) when is_map(attachments),
    do:
      map_size(attachments) <= 16 and
        Enum.all?(attachments, fn {label, bone} ->
          label?(label) and Map.has_key?(positions, bone)
        end)

  defp attachments?(_, _), do: false

  defp unique_roles?(bones) do
    roles = bones |> Enum.map(& &1.role) |> Enum.reject(&(&1 == ""))
    length(Enum.uniq(roles)) == length(roles)
  end

  defp bone_identity?(name, parent, role, positions),
    do:
      label?(name) and not Map.has_key?(positions, name) and parent?(parent, positions) and
        (role == "" or label?(role))
end
