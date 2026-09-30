param([ValidateSet('dev','perf')][string]$Profile = 'perf', [string]$Output)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Output) { $Output = Join-Path $root ('bench/results/outbound-{0}.jsonl' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')) }
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Output)) | Out-Null
if (Test-Path -LiteralPath $Output) { throw 'Benchmark output already exists' }
$previous = $env:WYRAM_OUTBOUND_BENCH_OUTPUT
try {
  $env:WYRAM_OUTBOUND_BENCH_OUTPUT = $Output
  cargo test --manifest-path (Join-Path $root 'native/Cargo.toml') --profile $Profile --locked -p wyram_client outbound::tests::benchmark_outbound_backpressure -- --ignored
  if ($LASTEXITCODE -ne 0) { throw 'Outbound benchmark failed' }
  $samples = @([IO.File]::ReadLines($Output) | ForEach-Object { $_ | ConvertFrom-Json })
  foreach ($async in @($false, $true)) {
    $runs = @($samples | Where-Object { $_.async -eq $async })
    $values = @($runs | ForEach-Object { $_.send_ms } | Sort-Object)
    $p95 = $values[[Math]::Ceiling($values.Count * 0.95) - 1]
    $p99 = $values[[Math]::Ceiling($values.Count * 0.99) - 1]
    Write-Host ('async={0}: admission p95={1:F6} p99={2:F6} ms; drained mean={3:F3} ms' -f $async, $p95, $p99, ($runs.drained_ms | Measure-Object -Average).Average)
  }
  Write-Host "Raw samples: $Output"
} finally { $env:WYRAM_OUTBOUND_BENCH_OUTPUT = $previous }
