defmodule WyramMods.Characters do
  @moduledoc "Original dwarf rigs authored in eight-pixel block units, with shared semantic roles."
  alias Wyram.Character.{Definition, Model, Profile}
  alias Wyram.Units

  def player_profile do
    %{
      Profile.default()
      | radius: Units.pixels(3),
        standing_height: Units.blocks(1, 3),
        standing_eye: Units.blocks(1, 1),
        crouch_height: Units.pixels(10),
        crouch_eye: Units.pixels(7),
        prone_height: Units.pixels(7),
        prone_eye: Units.pixels(4)
    }
  end

  def models,
    do: [
      dwarf("wyram/player", "hero", [72, 117, 79], [202, 164, 128]),
      dwarf("wyram/companion", "friend", [153, 89, 57], [178, 135, 102])
    ]

  def definitions do
    small = %{
      player_profile()
      | walk_speed: 3.2,
        run_speed: 6.5,
        climb_height: 2,
        wall_slide_enabled: false,
        roll_distance: 2.0
    }

    [
      Definition.player(player_profile(), "wyram/player"),
      %Definition{
        id: "companion",
        model: "wyram/companion",
        profile: small,
        position: {2.5, 71.38, -2.5}
      }
    ]
  end

  defp dwarf(id, prefix, shirt, skin) do
    bone = fn name, parent, role, pivot, boxes ->
      %{
        name: prefix <> "_" <> name,
        parent: if(parent, do: prefix <> "_" <> parent, else: nil),
        role: role,
        pivot: vector(pivot),
        boxes: boxes
      }
    end

    pants = [47, 55, 44]
    boots = [67, 48, 36]

    bones = [
      bone.("root", nil, "root", [0, 0, 0], []),
      bone.("hips", "root", "hips", [0, 2, 0], [
        box([0, 0.25, 0], [3.5, 0.5, 2.5], boots)
      ]),
      bone.("body", "hips", "torso", [0, 0, 0], [
        box([0, 1.5, 0], [3.5, 3, 2.5], shirt)
      ]),
      bone.("head", "body", "head", [0, 3, 0], [
        box([0, 3, 0], [6, 6, 5], skin),
        box([-1.3, 3.7, -2.52], [1.5, 0.8, 0.08], [232, 229, 205]),
        box([1.3, 3.7, -2.52], [1.5, 0.8, 0.08], [232, 229, 205]),
        box([-1.3, 3.7, -2.57], [0.6, 0.8, 0.04], [51, 89, 58]),
        box([1.3, 3.7, -2.57], [0.6, 0.8, 0.04], [51, 89, 58]),
        box([-1.3, 4.4, -2.52], [1.7, 0.35, 0.08], [65, 50, 36]),
        box([1.3, 4.4, -2.52], [1.7, 0.35, 0.08], [65, 50, 36])
      ]),
      bone.("arm_l", "body", "left_arm", [2.4, 3, 0], [
        box([0, -1, 0], [1.2, 2, 1.8], shirt),
        box([0, -2.5, 0], [1.2, 1, 1.8], skin)
      ]),
      bone.("arm_r", "body", "right_arm", [-2.4, 3, 0], [
        box([0, -1, 0], [1.2, 2, 1.8], shirt),
        box([0, -2.5, 0], [1.2, 1, 1.8], skin)
      ]),
      bone.("leg_l", "hips", "left_leg", [1, 0, 0], [
        box([0, -0.75, 0], [1.5, 1.5, 2], pants),
        box([0, -1.75, -0.2], [1.6, 0.5, 2.4], boots)
      ]),
      bone.("leg_r", "hips", "right_leg", [-1, 0, 0], [
        box([0, -0.75, 0], [1.5, 1.5, 2], pants),
        box([0, -1.75, -0.2], [1.6, 0.5, 2.4], boots)
      ]),
      bone.("grip_l", "arm_l", "", [0, -3, 0], []),
      bone.("grip_r", "arm_r", "", [0, -3, 0], []),
      bone.("hat", "head", "", [0, 6, 0], [])
    ]

    %Model{
      id: id,
      base_height: Units.blocks(1, 3),
      bones: bones,
      attachments: %{
        "left_hand" => prefix <> "_grip_l",
        "right_hand" => prefix <> "_grip_r",
        "head" => prefix <> "_hat"
      },
      capabilities: ["humanoid"]
    }
  end

  defp box(center, size, color), do: %{center: vector(center), size: vector(size), color: color}
  defp vector(values), do: Enum.map(values, &Units.pixels/1)
end
