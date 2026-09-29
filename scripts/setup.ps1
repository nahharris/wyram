$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  mix local.hex --force
  if ($LASTEXITCODE -ne 0) { throw 'Hex setup failed' }
  mix deps.get
  if ($LASTEXITCODE -ne 0) { throw 'Dependency fetch failed' }
  mix compile --warnings-as-errors
  if ($LASTEXITCODE -ne 0) { throw 'Elixir compile failed' }
  cargo build --manifest-path native/Cargo.toml --locked -p wyram_client
  if ($LASTEXITCODE -ne 0) { throw 'Native client build failed' }
  & (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name official
  $data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
  New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'dist\official.wyrplug') -Destination (Join-Path $data 'plugins\official.wyrplug') -Force
} finally { Pop-Location }
