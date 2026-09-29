$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\plugin-upgrade\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'dist\test_terrain.wyrplug') -Destination (Join-Path $data 'plugins\test_terrain.wyrplug')
$env:WYRAM_DATA_DIR = $data
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'

mix run scripts/test-plugin-initial.exs
if ($LASTEXITCODE -ne 0) { throw 'Initial world creation failed' }

Copy-Item -LiteralPath (Join-Path $root 'dist\test_addon.wyrplug') -Destination (Join-Path $data 'plugins\test_addon.wyrplug')
mix run scripts/test-plugin-added.exs
if ($LASTEXITCODE -ne 0) { throw 'World failed to load after installing a new plugin' }
