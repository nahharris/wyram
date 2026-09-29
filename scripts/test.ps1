$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testData = Join-Path $root ('.tools\test-run\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $testData 'plugins') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'dist\official.wyrplug') -Destination (Join-Path $testData 'plugins\official.wyrplug') -Force
$env:WYRAM_DATA_DIR = $testData
$env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
mix test
if ($LASTEXITCODE -ne 0) { throw 'ExUnit failed' }
cargo test --manifest-path native/Cargo.toml --workspace --locked
if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed' }
