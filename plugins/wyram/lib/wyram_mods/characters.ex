defmodule WyramMods.Characters do
  @moduledoc "Original Wyram cuboid character source assets; all distances are block units."
  alias Wyram.Character.{Definition, Model, Profile}

  def models,
    do: [
      humanoid("wyram/player", "hero", 1.0, [66, 112, 166]),
      humanoid("wyram/companion", "small", 1.4 / 1.8, [160, 86, 56])
    ]

  def definitions do
    small = %{
      Profile.default()
      | walk_speed: 3.2,
        run_speed: 6.5,
        radius: 0.22,
        standing_height: 1.4,
        standing_eye: 1.26,
        climb_height: 2,
        wall_slide_enabled: false,
        roll_distance: 2.0
    }

    [
      Definition.player(Profile.default(), "wyram/player"),
      %Definition{
        id: "companion",
        model: "wyram/companion",
        profile: small,
        position: {2.5, 71.38, -2.5}
      }
    ]
  end

  defp humanoid(id, prefix, scale, shirt) do
    bone = fn name, parent, role, pivot, boxes ->
      %{
        name: prefix <> "_" <> name,
        parent: if(parent, do: prefix <> "_" <> parent, else: nil),
        role: role,
        pivot: multiply(pivot, scale),
        boxes:
          Enum.map(boxes, fn box ->
            %{box | center: multiply(box.center, scale), size: multiply(box.size, scale)}
          end)
      }
    end

    skin = [192, 151, 112]
    pants = [48, 55, 70]

    bones = [
      bone.("root", nil, "root", [0, 0, 0], []),
      bone.("hips", "root", "hips", [0, 0.7, 0], [box([0, 0.1, 0], [0.46, 0.2, 0.26], pants)]),
      bone.("body", "hips", "torso", [0, 0.2, 0], [box([0, 0.28, 0], [0.48, 0.56, 0.28], shirt)]),
      bone.("head", "body", "head", [0, 0.6, 0], [
        box([0, 0.15, 0], [0.36, 0.3, 0.34], skin),
        box([-0.08, 0.17, -0.172], [0.04, 0.04, 0.012], [32, 32, 36]),
        box([0.08, 0.17, -0.172], [0.04, 0.04, 0.012], [32, 32, 36])
      ]),
      bone.("arm_l", "body", "left_arm", [0.32, 0.45, 0], [
        box([0, -0.25, 0], [0.16, 0.5, 0.2], skin)
      ]),
      bone.("arm_r", "body", "right_arm", [-0.32, 0.45, 0], [
        box([0, -0.25, 0], [0.16, 0.5, 0.2], skin)
      ]),
      bone.("leg_l", "hips", "left_leg", [0.14, 0, 0], [
        box([0, -0.35, 0], [0.2, 0.7, 0.24], pants)
      ]),
      bone.("leg_r", "hips", "right_leg", [-0.14, 0, 0], [
        box([0, -0.35, 0], [0.2, 0.7, 0.24], pants)
      ]),
      bone.("grip_l", "arm_l", "", [0, -0.5, 0], []),
      bone.("grip_r", "arm_r", "", [0, -0.5, 0], []),
      bone.("hat", "head", "", [0, 0.3, 0], [])
    ]

    %Model{
      id: id,
      base_height: 1.8 * scale,
      bones: bones,
      attachments: %{
        "left_hand" => prefix <> "_grip_l",
        "right_hand" => prefix <> "_grip_r",
        "head" => prefix <> "_hat"
      },
      capabilities: ["humanoid"]
    }
  end

  defp box(center, size, color), do: %{center: center, size: size, color: color}
  defp multiply(vector, scale), do: Enum.map(vector, &(&1 * scale))
end
