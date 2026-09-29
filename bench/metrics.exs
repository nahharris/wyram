defmodule Wyram.Bench.Metrics do
  @moduledoc "Small, dependency-free summaries for repeatable local benchmarks."

  def summary([_ | _] = samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)

    %{
      samples_ms: samples,
      p50_ms: Enum.at(sorted, ceil(count * 0.50) - 1),
      p95_ms: Enum.at(sorted, ceil(count * 0.95) - 1),
      mean_ms: Enum.sum(samples) / count
    }
  end
end
