Code.require_file(Path.expand("../../../bench/metrics.exs", __DIR__))

defmodule Wyram.Engine.BenchmarkMetricsTest do
  use ExUnit.Case, async: true
  alias Wyram.Bench.Metrics

  test "nearest-rank percentiles keep small benchmark samples interpretable" do
    assert Metrics.summary([4.0, 1.0, 3.0, 2.0]) == %{
             samples_ms: [4.0, 1.0, 3.0, 2.0],
             p50_ms: 2.0,
             p95_ms: 4.0,
             mean_ms: 2.5
           }
  end
end
