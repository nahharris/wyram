$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  $env:MIX_ENV = 'dev'
  & (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram

  cargo build --manifest-path native/Cargo.toml --release --locked -p wyram_client
  if ($LASTEXITCODE -ne 0) { throw 'Native release build failed' }

  $env:MIX_ENV = 'prod'
  mix deps.get --only prod
  if ($LASTEXITCODE -ne 0) { throw 'Production dependency fetch failed' }
  mix release --overwrite
  if ($LASTEXITCODE -ne 0) { throw 'Engine release failed' }

  $stage = Join-Path $root 'dist\windows'
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'plugins') | Out-Null
  Remove-Item -LiteralPath (Join-Path $stage 'plugins\official.wyrplug') -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath (Join-Path $root 'native\target\release\wyram_client.exe') -Destination $stage -Force
  Copy-Item -LiteralPath (Join-Path $root 'dist\wyram.wyrplug') -Destination (Join-Path $stage 'plugins') -Force
  Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $stage -Force
  Copy-Item -LiteralPath (Join-Path $root '_build\prod\rel\wyram') -Destination (Join-Path $stage 'engine') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $root 'scripts\run-packaged.ps1') -Destination (Join-Path $stage 'run.ps1') -Force

  $env:WYRAM_DATA_DIR = Join-Path $root ('dist\release-smoke\' + [guid]::NewGuid().ToString('N'))
  $env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
  New-Item -ItemType Directory -Force -Path (Join-Path $env:WYRAM_DATA_DIR 'plugins') | Out-Null
  Copy-Item -LiteralPath (Join-Path $stage 'plugins\wyram.wyrplug') -Destination (Join-Path $env:WYRAM_DATA_DIR 'plugins\wyram.wyrplug') -Force
  & (Join-Path $stage 'engine\bin\wyram.bat') eval 'Application.ensure_all_started(:wyram_engine); 1 = Wyram.Engine.World.get_block(0, 60, 0)'
  if ($LASTEXITCODE -ne 0) { throw 'Packaged release smoke test failed' }
} finally {
  $env:MIX_ENV = 'dev'
  Pop-Location
}
