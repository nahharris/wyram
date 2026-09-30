$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
cargo build --manifest-path (Join-Path $root 'native\Cargo.toml') --locked -p wyram_client
if ($LASTEXITCODE -ne 0) { throw 'Native client build failed' }
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
Invoke-WithDevelopmentPlugin -Package (Join-Path $root 'dist\wyram.wyrplug') -DataDirectory $data -Run {
  mix run --no-halt
  if ($LASTEXITCODE -ne 0) { throw 'Game exited with an error' }
}
