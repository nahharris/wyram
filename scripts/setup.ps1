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
  & (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
  $data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
  New-Item -ItemType Directory -Force -Path (Join-Path $data 'plugins') | Out-Null
  $legacy = Join-Path $data 'plugins\official.wyrplug'
  if (Test-Path -LiteralPath $legacy) {
    Move-Item -LiteralPath $legacy -Destination ($legacy + '.' + [guid]::NewGuid().ToString('N') + '.disabled')
  }
  Copy-Item -LiteralPath (Join-Path $root 'dist\wyram.wyrplug') -Destination (Join-Path $data 'plugins\wyram.wyrplug') -Force
} finally { Pop-Location }
