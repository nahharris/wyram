if metrics = System.get_env("WYRAM_CLIENT_METRICS") do
  {profile, opt_level} = Wyram.Engine.Native.build_info()
  library = Wyram.Engine.Native.library_path()
  sha256 = File.read!(library) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  report =
    Jason.encode!(%{profile: profile, opt_level: opt_level, sha256: sha256, library: library})

  output = Path.rootname(metrics) <> ".native.json"

  with :ok <- File.mkdir_p(Path.dirname(output)),
       :ok <- File.write(output, report, [:exclusive]) do
    :ok
  else
    error -> IO.puts(:stderr, "Native build capture unavailable: #{inspect(error)}")
  end
end

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
