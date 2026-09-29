$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\official-smoke\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'dist\official.wyrplug') -Destination (Join-Path $data 'plugins\official.wyrplug')
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
mix run scripts/test-official-smoke.exs
if ($LASTEXITCODE -ne 0) { throw 'Official plugin smoke test failed' }
