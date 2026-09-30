status =
  case Wyram.Engine.ClientPort.await_exit() do
    {:ok, status} ->
      status

    {:error, :client_unavailable} ->
      IO.puts(:stderr, "Game cannot start: native client unavailable")
      1
  end

# Orderly OTP shutdown, including supervised applications. Wait for it rather
# than returning to Mix (which would otherwise choose its own exit status).
System.stop(status)
Process.sleep(:infinity)
