$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root ('.tools\benchmark-test\' + [guid]::NewGuid().ToString('N') + '.json')
& (Join-Path $PSScriptRoot 'bench.ps1') -Rounds 2 -Output $output
if ($LASTEXITCODE -ne 0) { throw 'Benchmark smoke run failed' }
$result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
if ($result.schema -ne 1 -or $result.workload.rounds -ne 2 -or
    $result.metrics.serial_chunks.samples_ms.Count -ne 2 -or
    $result.metrics.parallel_chunks.samples_ms.Count -ne 2 -or
    $result.metrics.warm_block_read.p50_ms -le 0 -or
    $result.plugin_versions.test_terrain -ne '0.1.0' -or
    $result.commit -notmatch '^[0-9a-f]{40}$') {
  throw 'Benchmark result is incomplete'
}
