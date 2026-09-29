$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\wyram-smoke\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'dist\wyram.wyrplug') -Destination (Join-Path $data 'plugins\wyram.wyrplug')
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
mix run scripts/test-wyram-smoke.exs
if ($LASTEXITCODE -ne 0) { throw 'Wyram plugin smoke test failed' }
