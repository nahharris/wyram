defmodule Wyram.Character.State do
  @moduledoc "Pure fixed-step character authority, independent of actor ownership and presentation."
  alias Wyram.Character.{Flight, Input, Motion, Profile}
  @tick_ms 20
  defstruct position: {0.5, 71.38, 0.5},
            velocity: {0.0, 0.0, 0.0},
            profile: nil,
            model: "default",
            grounded: false,
            jump_held: false,
            flight_request: 0,
            jump_pending: nil,
            jump_origin: nil,
            transition: :idle,
            transition_time: 0.0,
            last_posture: :stand,
            climb_held: false,
            roll_held: false,
            roll_cooldown: 0.0,
            action: nil,
            unavailable: false,
            mode: :walk,
            posture: :stand,
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
          model: String.t(),
          grounded: boolean(),
          jump_held: boolean(),
          flight_request: non_neg_integer(),
          jump_pending: number() | nil,
          jump_origin: vector() | nil,
          transition: atom(),
          transition_time: number(),
          last_posture: atom(),
          climb_held: boolean(),
          roll_held: boolean(),
          roll_cooldown: number(),
          action: map() | nil,
          unavailable: boolean(),
          mode: atom(),
          posture: atom(),
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
  def new(profile, position),
    do: %__MODULE__{
      profile: profile,
      position: position,
      radius: profile.radius,
      height: profile.standing_height,
      eye_height: profile.standing_eye
    }

  @doc "The authoritative timestep; render frequency never changes jump integration."
  @spec tick_ms() :: pos_integer()
  def tick_ms, do: @tick_ms

  @spec prepare(t(), Input.t()) :: {t(), query()}
  def prepare(state, input) do
    state = Flight.begin(state, input)
    if state.mode == :fly, do: Flight.prepare(state, input), else: prepare_ground(state, input)
  end

  defp prepare_ground(state, input) do
    motion = Profile.motion(state.profile, input.running)

    motion = posture_motion(state, motion)

    Motion.prepare(state, input, motion)
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

    grounded = not unavailable and hit_y and vy < 0
    state = %{state | velocity: velocity} |> Flight.landed(grounded) |> Motion.landed(grounded)

    %{
      state
      | position: position,
        velocity: state.velocity,
        grounded: grounded,
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
      model: state.model,
      standing_height: state.profile.standing_height,
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
      mode: state.mode,
      action: snapshot_action(state.action),
      posture: state.posture,
      transition: state.transition
    }
  end

  defp posture_motion(%{posture: :crouch, profile: p}, motion),
    do: %{motion | mode: :sneak, speed: p.sneak_speed}

  defp posture_motion(%{posture: :prone, profile: p}, motion),
    do: %{motion | mode: :crawl, speed: p.crawl_speed}

  defp posture_motion(_, motion), do: motion
  defp snapshot_action(nil), do: nil

  defp snapshot_action(action) do
    Map.new(action, fn {key, value} ->
      {key, if(is_tuple(value), do: Tuple.to_list(value), else: value)}
    end)
  end
end
