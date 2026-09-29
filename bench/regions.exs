# Run after `mise run setup`: mise exec -- mix run bench/regions.exs
alias Wyram.Engine.World

region_chunks = fn offset ->
  for region <- 0..3 do
    for x <- 0..3, z <- 0..3, do: {offset + region * 4 + x, 3, z}
  end
end

run = fn regions, parallel? ->
  worker = fn chunks ->
    Enum.each(chunks, fn {cx, cy, cz} ->
      %{data: data} = World.get_chunk(cx, cy, cz)
      8192 = byte_size(data)
    end)
  end

  :erlang.garbage_collect()

  {microseconds, _} =
    :timer.tc(fn ->
      if parallel? do
        regions |> Enum.map(&Task.async(fn -> worker.(&1) end)) |> Task.await_many(60_000)
      else
        Enum.each(regions, worker)
      end
    end)

  microseconds / 1000
end

samples =
  for round <- 0..5 do
    serial = run.(region_chunks.(round * 64), false)
    parallel = run.(region_chunks.(round * 64 + 32), true)

    IO.puts(
      "round #{round + 1}: serial=#{Float.round(serial, 2)} ms parallel=#{Float.round(parallel, 2)} ms"
    )

    {serial, parallel}
  end

median = fn values ->
  sorted = Enum.sort(values)
  Enum.at(sorted, div(length(sorted), 2))
end

serial = samples |> Enum.map(&elem(&1, 0)) |> median.()
parallel = samples |> Enum.map(&elem(&1, 1)) |> median.()
IO.puts("median: serial=#{Float.round(serial, 2)} ms parallel=#{Float.round(parallel, 2)} ms")
IO.puts("relative throughput: #{Float.round(serial / parallel, 2)}x")
