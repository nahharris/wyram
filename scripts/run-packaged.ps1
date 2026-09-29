$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
$plugins = Join-Path $data 'plugins'
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
$legacy = Join-Path $plugins 'official.wyrplug'
if (Test-Path -LiteralPath $legacy) {
  Move-Item -LiteralPath $legacy -Destination ($legacy + '.' + [guid]::NewGuid().ToString('N') + '.disabled')
}
$wyram = Join-Path $plugins 'wyram.wyrplug'
if (-not (Test-Path -LiteralPath $wyram)) {
  Copy-Item -LiteralPath (Join-Path $package 'plugins\wyram.wyrplug') -Destination $wyram
}
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = Join-Path $package 'wyram_client.exe'
& (Join-Path $package 'engine\bin\wyram.bat') start
if ($LASTEXITCODE -ne 0) { throw "Wyram exited with code $LASTEXITCODE" }
