param([ValidateSet('dev','perf')][string]$Profile = 'dev')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
cargo build --manifest-path (Join-Path $root 'native\Cargo.toml') --profile $Profile --locked -p wyram_client
if ($LASTEXITCODE -ne 0) { throw 'Native client build failed' }
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
$previousClient = $env:WYRAM_CLIENT
try {
  $output = if ($Profile -eq 'dev') { 'debug' } else { $Profile }
  if (-not $env:WYRAM_CLIENT) { $env:WYRAM_CLIENT = Join-Path $root "native\target\$output\wyram_client.exe" }
  Invoke-WithDevelopmentPlugin -Package (Join-Path $root 'dist\wyram.wyrplug') -DataDirectory $data -Run {
    mix run --no-halt
    if ($LASTEXITCODE -ne 0) { throw 'Game exited with an error' }
  }
} finally { $env:WYRAM_CLIENT = $previousClient }
