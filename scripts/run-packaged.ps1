$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
$plugins = Join-Path $data 'plugins'
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
$official = Join-Path $plugins 'official.wyrplug'
if (-not (Test-Path -LiteralPath $official)) {
  Copy-Item -LiteralPath (Join-Path $package 'plugins\official.wyrplug') -Destination $official
}
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = Join-Path $package 'wyram_client.exe'
& (Join-Path $package 'engine\bin\wyram.bat') start
if ($LASTEXITCODE -ne 0) { throw "Wyram exited with code $LASTEXITCODE" }
