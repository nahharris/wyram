param([int]$Rounds = 5, [string]$Output)
$ErrorActionPreference = 'Stop'
if ($Rounds -lt 1 -or $Rounds -gt 20) { throw 'Rounds must be between 1 and 20' }
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\bench\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name test_terrain
if ($LASTEXITCODE -ne 0) { throw 'Test plugin packaging failed' }
Copy-Item -LiteralPath (Join-Path $root 'dist\test_terrain.wyrplug') -Destination (Join-Path $data 'plugins\test_terrain.wyrplug')

if (-not $Output) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $Output = Join-Path $root ("bench\results\$stamp.json")
}
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
$env:WYRAM_CONTROL_PORT = $null
$env:WYRAM_BENCH_OUTPUT = [IO.Path]::GetFullPath($Output)
$env:WYRAM_BENCH_ROUNDS = [string]$Rounds
Push-Location $root
try {
  mix run bench/suite.exs
  if ($LASTEXITCODE -ne 0) { throw 'Benchmark failed' }
} finally { Pop-Location }
