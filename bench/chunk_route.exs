# Isolated desktop diagnostic: stream startup, hover, real authoritative flight, drain.
# Invoke with a fresh WYRAM_DATA_DIR and new WYRAM_CLIENT_METRICS path.
alias Wyram.Engine.{Characters, ClientPort, World}

capture = System.fetch_env!("WYRAM_CLIENT_METRICS")
output = System.fetch_env!("WYRAM_FLIGHT_PHASES")
false = File.exists?(output)

wait = fn wait, remaining ->
  case ClientPort.snapshot() do
    %{connected: true, player: player} when is_map(player) ->
      player

    _ when remaining > 0 ->
      Process.sleep(100)
      wait.(wait, remaining - 1)

    _ ->
      raise "renderer did not report player state"
  end
end

player = wait.(wait, 300)
{_, high} = World.generation().bounds

altitude =
  case System.get_env("WYRAM_FLIGHT_HEIGHT_OFFSET") do
    nil -> high - 8.0
    offset -> min(player.y + String.to_integer(offset), high - 8.0)
  end

:ok = ClientPort.teleport(player.x, altitude, player.z, 0.0, -0.35)
epoch = Characters.snapshot().epoch

mark = fn name ->
  # The telemetry writer buffers bytes. These boundaries lag by a small number
  # of frames; exclude one second at both phase edges in percentile summaries.
  frames =
    case File.read(capture) do
      {:ok, bytes} -> length(:binary.matches(bytes, "\n"))
      {:error, :enoent} -> 0
    end

  IO.puts("flight phase: #{name}, persisted frames: #{frames}")

  %{
    phase: name,
    persisted_frames: frames,
    utc: DateTime.utc_now(),
    player: Characters.snapshot(),
    client_call_us: Process.delete(:client_call_us) || [],
    client_mailbox_max: Process.delete(:client_mailbox_max) || 0
  }
end

drive = fn duration, forward, first_sequence ->
  Enum.each(0..(div(duration, 100) - 1), fn index ->
    Characters.input(%{
      "sequence" => first_sequence + index,
      "epoch" => epoch,
      "forward" => forward,
      "right" => 0.0,
      "yaw" => 0.0,
      "pitch" => -0.35,
      "running" => true,
      "jump" => false,
      "flight_request" => 1
    })

    if System.get_env("WYRAM_STREAM_RESPONSIVENESS") == "1" do
      {us, _} = :timer.tc(fn -> ClientPort.snapshot() end)
      Process.put(:client_call_us, [us | Process.get(:client_call_us, [])])
      {:message_queue_len, queued} = Process.info(Process.whereis(ClientPort), :message_queue_len)
      Process.put(:client_mailbox_max, max(queued, Process.get(:client_mailbox_max, 0)))
    end

    Process.sleep(100)
  end)
end

start = mark.("startup")
startup_ms = System.get_env("WYRAM_ROUTE_STARTUP_MS", "35000") |> String.to_integer()
drain_ms = System.get_env("WYRAM_ROUTE_DRAIN_MS", "35000") |> String.to_integer()
true = startup_ms in 1000..120_000 and rem(startup_ms, 100) == 0
true = drain_ms in 1000..120_000 and rem(drain_ms, 100) == 0
drive.(startup_ms, 0.0, 10_000)
hover = mark.("hover")
:fly = Characters.snapshot().mode
drive.(6_000, 0.0, 20_000)
flight = mark.("flight")
target_z = flight.player.z - 96.0

Enum.reduce_while(0..399, nil, fn index, _ ->
  drive.(100, 1.0, 30_000 + index)

  if Characters.snapshot().z <= target_z,
    do: {:halt, nil},
    else: {:cont, nil}
end)

drain = mark.("drain")
true = drain.player.z <= target_z
drive.(drain_ms, 0.0, 40_000)
finish = mark.("finish")
:fly = finish.player.mode
false = finish.player.unavailable
true = flight.player.z - drain.player.z >= 32.0
true = finish.persisted_frames > flight.persisted_frames

nif_path = Path.join(to_string(:code.priv_dir(:wyram_engine)), "native/wyram_nif.dll")
nif_hash = File.read!(nif_path) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16()

File.mkdir_p!(Path.dirname(output))

File.write!(
  output,
  Jason.encode!(%{schema: 1, nif_sha256: nif_hash, phases: [start, hover, flight, drain, finish]})
)

:ok = Application.stop(:wyram_engine)
Process.sleep(500)
