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
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  $resolvedStage = [IO.Path]::GetFullPath($stage)
  if (-not $resolvedStage.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package stage escapes the workspace'
  }
  if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'plugins') | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'native\target\release\wyram_client.exe') -Destination $stage -Force
  Copy-Item -LiteralPath (Join-Path $root 'dist\wyram.wyrplug') -Destination (Join-Path $stage 'plugins') -Force
  Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $stage -Force
  Copy-Item -LiteralPath (Join-Path $root '_build\prod\rel\wyram') -Destination (Join-Path $stage 'engine') -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $root 'scripts\run-packaged.ps1') -Destination (Join-Path $stage 'run.ps1') -Force

  $env:WYRAM_DATA_DIR = Join-Path $root ('dist\release-smoke\' + [guid]::NewGuid().ToString('N'))
  $env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
  $env:WYRAM_CONTROL_PORT = '0'
  New-Item -ItemType Directory -Force -Path (Join-Path $env:WYRAM_DATA_DIR 'plugins') | Out-Null
  Copy-Item -LiteralPath (Join-Path $stage 'plugins\wyram.wyrplug') -Destination (Join-Path $env:WYRAM_DATA_DIR 'plugins\wyram.wyrplug') -Force
  & (Join-Path $stage 'engine\bin\wyram.bat') eval 'Application.ensure_all_started(:wyram_engine); true = List.keymember?(Supervisor.which_children(Wyram.Engine.Supervisor), Wyram.Engine.Control, 0); config = Wyram.Engine.PluginManager.worldgen(); true = config.height == 512 and config.sea_level == 0; true = Wyram.Engine.World.generation().bounds == {-192, 319}; true = Wyram.Engine.World.get_block(0, config.min_y, 0) == Map.get(Wyram.Engine.PluginManager.blocks(), ~s(wyram:stone)); true = byte_size(Wyram.Engine.World.get_chunk(0, -12, 0).data) == 8192'
  if ($LASTEXITCODE -ne 0) { throw 'Packaged release smoke test failed' }
} finally {
  $env:MIX_ENV = 'dev'
  $env:WYRAM_CONTROL_PORT = $null
  Pop-Location
}
