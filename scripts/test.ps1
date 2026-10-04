$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testData = Join-Path $root ('.tools\test-run\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $testData 'plugins') | Out-Null
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name test_terrain
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name test_addon
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
& (Join-Path $PSScriptRoot 'test-plugin-archive.ps1')
& (Join-Path $PSScriptRoot 'test-dev-plugin.ps1')
& (Join-Path $PSScriptRoot 'test-dev-profile.ps1')
& (Join-Path $PSScriptRoot 'test-dev-exit.ps1')
Copy-Item -LiteralPath (Join-Path $root 'dist\test_terrain.wyrplug') -Destination (Join-Path $testData 'plugins\test_terrain.wyrplug') -Force
Copy-Item -LiteralPath (Join-Path $root 'dist\test_addon.wyrplug') -Destination (Join-Path $testData 'plugins\test_addon.wyrplug') -Force
& (Join-Path $PSScriptRoot 'test-plugin-upgrade.ps1')
& (Join-Path $PSScriptRoot 'test-wyram-smoke.ps1')
$env:WYRAM_DATA_DIR = $testData
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
mix test
if ($LASTEXITCODE -ne 0) { throw 'ExUnit failed' }
cargo test --manifest-path native/Cargo.toml --workspace --locked
if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed' }
& (Join-Path $PSScriptRoot 'test-scenery-wire.ps1')
& (Join-Path $PSScriptRoot 'test-benchmark.ps1')

cargo run --manifest-path native/Cargo.toml -p wyram_client --locked -- --validate-models .tools/character-models.json
if ($LASTEXITCODE -ne 0) { throw 'Original character model import failed' }
