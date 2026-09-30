defmodule Wyram.Engine.Characters do
  @moduledoc "A shared fixed-step owner of dense character state and coalesced presentation snapshots."
  use GenServer
  alias Wyram.Character.{Input, State, Step}
  alias Wyram.Engine.{ClientPort, Collision, PluginManager}
  @table :wyram_character_snapshots

  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  def connect(server \\ __MODULE__), do: GenServer.cast(server, :connect)
  def disconnect(server \\ __MODULE__), do: GenServer.cast(server, :disconnect)
  def input(packet, server \\ __MODULE__), do: GenServer.cast(server, {:input, packet})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def acknowledge, do: GenServer.cast(__MODULE__, :acknowledge)
  def latest, do: :ets.lookup_element(@table, :latest, 2)

  def teleport(x, y, z, yaw, pitch, server \\ __MODULE__),
    do: GenServer.call(server, {:teleport, x, y, z, yaw, pitch})

  @impl true
  def init(options) do
    profile =
      case Keyword.fetch(options, :profile) do
        {:ok, profile} -> profile
        :error -> PluginManager.player_profile()
      end

    table =
      if Keyword.get(options, :name, __MODULE__) == __MODULE__,
        do: :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true]),
        else: :ets.new(@table, [:set, :protected])

    state = %{
      bodies: %{"player" => State.new(profile, {0.5, 71.38, 0.5})},
      input: Input.idle(),
      received_at: 0,
      active: false,
      collision: Keyword.get(options, :collision, &Collision.sweep/1),
      table: table,
      notified: false,
      publish:
        Keyword.get(options, :publish, fn _ -> GenServer.cast(ClientPort, :characters_ready) end),
      tick: Keyword.get(options, :tick, true)
    }

    epoch = if table == @table, do: System.unique_integer([:positive, :monotonic]), else: 0
    body = %{state.bodies["player"] | epoch: epoch}
    state = %{state | bodies: %{"player" => body}, input: %{state.input | epoch: epoch}}
    :ets.insert(table, {:latest, [Map.put(State.snapshot(body), :id, "player")]})

    if table == @table and Process.whereis(ClientPort),
      do: GenServer.cast(ClientPort, :characters_restarted)

    if state.tick, do: Process.send_after(self(), :tick, State.tick_ms())
    {:ok, state}
  end

  @impl true
  def handle_cast(:connect, state), do: {:noreply, notify(%{state | active: true})}

  def handle_cast(:disconnect, state),
    do: {:noreply, %{state | active: false, input: Input.idle(), notified: false}}

  def handle_cast(:acknowledge, state), do: {:noreply, %{state | notified: false}}

  def handle_cast({:input, packet}, state) do
    body = state.bodies["player"]

    case Input.decode(packet) do
      {:ok, input} when input.epoch == body.epoch and input.sequence > state.input.sequence ->
        {:noreply, %{state | input: input, received_at: System.monotonic_time(:millisecond)}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, State.snapshot(state.bodies["player"]), state}

  def handle_call({:teleport, x, y, z, yaw, pitch}, _from, state) do
    body = state.bodies["player"]
    position = {x / 1, y / 1 - body.eye_height, z / 1}
    query = {position, {0.0, 0.0, 0.0}, body.radius, body.height}

    with true <- Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 1_000_000)),
         {:ok, [{_, {false, false, false}, false}]} <- state.collision.([query]) do
      next = %{
        body
        | position: position,
          velocity: {0.0, 0.0, 0.0},
          grounded: false,
          jump_held: false,
          climb_held: false,
          action: nil,
          sequence: body.sequence + 1,
          input_sequence: 0,
          epoch:
            if(state.table == @table,
              do: System.unique_integer([:positive, :monotonic]),
              else: body.epoch + 1
            ),
          yaw: yaw / 1,
          pitch: pitch / 1
      }

      idle = %{Input.idle() | epoch: next.epoch, yaw: next.yaw, pitch: next.pitch}
      state = %{state | bodies: Map.put(state.bodies, "player", next), input: idle}
      {:reply, :ok, notify(state)}
    else
      _ -> {:reply, {:error, :blocked_destination}, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    if state.tick, do: Process.send_after(self(), :tick, State.tick_ms())
    next = if state.active, do: advance(state), else: state
    {:noreply, next}
  end

  defp advance(state) do
    stale = System.monotonic_time(:millisecond) - state.received_at > 250

    input =
      if stale,
        do: %{
          state.input
          | forward: 0.0,
            right: 0.0,
            jump: false,
            running: false,
            sneaking: false,
            crawling: false,
            climbing: false
        },
        else: state.input

    entries = Enum.map(state.bodies, fn {id, body} -> {id, body, input} end)

    bodies =
      case Step.advance(entries, state.collision) do
        {:ok, bodies} ->
          bodies

        {:error, _} ->
          Map.new(state.bodies, fn {id, body} ->
            {id,
             State.finish(%{body | action: nil}, {body.position, {false, false, false}, true})}
          end)
      end

    notify(%{state | bodies: bodies})
  end

  defp notify(state) do
    batch = Enum.map(state.bodies, fn {id, body} -> Map.put(State.snapshot(body), :id, id) end)
    :ets.insert(state.table, {:latest, batch})
    if not state.notified, do: state.publish.(batch)
    %{state | notified: true}
  end
end
