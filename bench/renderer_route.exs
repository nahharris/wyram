alias Wyram.Engine.ClientPort

wait = fn wait, remaining ->
  case ClientPort.snapshot() do
    %{connected: true, player: player} when is_map(player) ->
      :ok

    _ when remaining > 0 ->
      Process.sleep(100)
      wait.(wait, remaining - 1)

    _ ->
      raise "renderer did not report player state"
  end
end

wait.(wait, 150)
Process.sleep(2_000)

for x <- [0.5, 16.5, 32.5, 48.5, 64.5, -32.5, -16.5, 0.5] do
  :ok = ClientPort.teleport(x, 73.0, 0.5, 0.0, -0.15)
  Process.sleep(800)
end

Process.sleep(2_000)
:ok = Application.stop(:wyram_engine)
Process.sleep(500)
