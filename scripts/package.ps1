$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  $env:MIX_ENV = 'dev'
  & (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram

  cargo build --manifest-path native/Cargo.toml --release --locked -p wyram_client -p wyram_nif
  if ($LASTEXITCODE -ne 0) { throw 'Native release build failed' }
  # Profile switches can leave a development DLL in the shared source priv tree.
  # Stage the actual release library even when Mix reuses its compiled modules.
  $releaseNativeDirectory = Join-Path $root 'apps\wyram_engine\priv\native'
  New-Item -ItemType Directory -Force -Path $releaseNativeDirectory | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'native\target\release\wyram_nif.dll') -Destination (Join-Path $releaseNativeDirectory 'wyram_nif.dll') -Force

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
  # Development profile artifacts are local build outputs, not package contents.
  $packagedNativeDirectories = @(Get-ChildItem -LiteralPath (Join-Path $stage 'engine\lib') -Directory -Filter 'wyram_engine-*' |
    ForEach-Object { Join-Path $_.FullName 'priv\native' })
  $packagedNativeFiles = @($packagedNativeDirectories | ForEach-Object { Get-ChildItem -LiteralPath $_ -File })
  $packagedNativeFiles |
    Where-Object { $_.Name -match '^wyram_nif_(dev|perf)_[0-9a-f]{64}\.dll$' } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  $packagedNativeLibraries = @($packagedNativeDirectories | ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Filter 'wyram_nif*.dll' })
  if ($packagedNativeLibraries.Count -ne 1 -or $packagedNativeLibraries[0].Name -ne 'wyram_nif.dll') {
    throw 'Package must contain only the release generation library'
  }
  Copy-Item -LiteralPath (Join-Path $root 'scripts\run-packaged.ps1') -Destination (Join-Path $stage 'run.ps1') -Force

  $env:WYRAM_DATA_DIR = Join-Path $root ('dist\release-smoke\' + [guid]::NewGuid().ToString('N'))
  $env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
  $env:WYRAM_CONTROL_PORT = '0'
  New-Item -ItemType Directory -Force -Path (Join-Path $env:WYRAM_DATA_DIR 'plugins') | Out-Null
  Copy-Item -LiteralPath (Join-Path $stage 'plugins\wyram.wyrplug') -Destination (Join-Path $env:WYRAM_DATA_DIR 'plugins\wyram.wyrplug') -Force
  & (Join-Path $stage 'engine\bin\wyram.bat') eval 'Application.ensure_all_started(:wyram_engine); true = Wyram.Engine.Native.build_info() == {~s(release), ~s(3)}; true = List.keymember?(Supervisor.which_children(Wyram.Engine.Supervisor), Wyram.Engine.Control, 0); config = Wyram.Engine.PluginManager.worldgen(); true = config.height == 512 and config.sea_level == 0; true = Wyram.Engine.World.generation().bounds == {-192, 319}; true = Wyram.Engine.World.get_block(0, config.min_y, 0) == Map.get(Wyram.Engine.PluginManager.blocks(), ~s(wyram:stone)); true = byte_size(Wyram.Engine.World.get_chunk(0, -12, 0).data) == 8192'
  if ($LASTEXITCODE -ne 0) { throw 'Packaged release smoke test failed' }
} finally {
  $env:MIX_ENV = 'dev'
  $env:WYRAM_CONTROL_PORT = $null
  Pop-Location
}
