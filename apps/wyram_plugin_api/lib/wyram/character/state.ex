defmodule Wyram.Character.State do
  @moduledoc "Pure fixed-step character authority, independent of actor ownership and presentation."
  alias Wyram.Character.{Input, Profile}
  @dt 0.02
  defstruct position: {0.5, 71.38, 0.5},
            velocity: {0.0, 0.0, 0.0},
            profile: nil,
            grounded: false,
            jump_held: false,
            unavailable: false,
            mode: :walk,
            radius: 0.28,
            height: 1.8,
            eye_height: 1.62,
            yaw: 0.0,
            pitch: -0.15,
            sequence: 0,
            input_sequence: 0,
            epoch: 0

  @type vector :: {number(), number(), number()}
  @type t :: %__MODULE__{
          position: vector(),
          velocity: vector(),
          profile: Profile.t(),
          grounded: boolean(),
          jump_held: boolean(),
          unavailable: boolean(),
          mode: atom(),
          radius: number(),
          height: number(),
          eye_height: number(),
          yaw: number(),
          pitch: number(),
          sequence: non_neg_integer(),
          input_sequence: non_neg_integer(),
          epoch: non_neg_integer()
        }
  @type query :: {vector(), vector(), number(), number()}
  @type result :: {vector(), {boolean(), boolean(), boolean()}, boolean()}
  @spec new(Profile.t(), vector()) :: t()
  def new(profile, position), do: %__MODULE__{profile: profile, position: position}

  @spec prepare(t(), Input.t()) :: {t(), query()}
  def prepare(state, input) do
    motion = Profile.motion(state.profile, input.running)
    length = max(1.0, :math.sqrt(input.forward * input.forward + input.right * input.right))

    vx =
      (:math.sin(input.yaw) * input.forward + :math.cos(input.yaw) * input.right) / length *
        motion.speed

    vz =
      (-:math.cos(input.yaw) * input.forward + :math.sin(input.yaw) * input.right) / length *
        motion.speed

    initial_vy =
      if state.grounded and input.jump and not state.jump_held,
        do: motion.jump_speed,
        else: elem(state.velocity, 1)

    vy = max(initial_vy - motion.gravity * @dt, -motion.terminal_speed)
    delta = {vx * @dt, (initial_vy + vy) * 0.5 * @dt, vz * @dt}

    next = %{
      state
      | velocity: {vx, vy, vz},
        jump_held: input.jump,
        mode: motion.mode,
        yaw: input.yaw,
        pitch: input.pitch,
        input_sequence: input.sequence
    }

    {next, {state.position, delta, state.radius, state.height}}
  end

  @spec finish(t(), result()) :: t()
  def finish(state, {position, {hit_x, hit_y, hit_z}, unavailable}) do
    {vx, vy, vz} = state.velocity

    velocity =
      if unavailable,
        do: {0.0, 0.0, 0.0},
        else:
          {if(hit_x, do: 0.0, else: vx), if(hit_y, do: 0.0, else: vy),
           if(hit_z, do: 0.0, else: vz)}

    %{
      state
      | position: position,
        velocity: velocity,
        grounded: not unavailable and hit_y and vy < 0,
        unavailable: unavailable,
        sequence: state.sequence + 1
    }
  end

  @spec snapshot(t()) :: map()
  def snapshot(state) do
    {x, y, z} = state.position

    %{
      x: x,
      y: y + state.eye_height,
      z: z,
      feet: Tuple.to_list(state.position),
      velocity: Tuple.to_list(state.velocity),
      eye_height: state.eye_height,
      height: state.height,
      radius: state.radius,
      yaw: state.yaw,
      pitch: state.pitch,
      sequence: state.sequence,
      input_sequence: state.input_sequence,
      epoch: state.epoch,
      grounded: state.grounded,
      unavailable: state.unavailable,
      mode: state.mode
    }
  end
end
