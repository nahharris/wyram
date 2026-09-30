param([ValidateSet('dev','perf')][string]$Profile = 'dev')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
cargo build --manifest-path (Join-Path $root 'native\Cargo.toml') --profile $Profile --locked -p wyram_client
if ($LASTEXITCODE -ne 0) { throw 'Native client build failed' }
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
$previousClient = $env:WYRAM_CLIENT
$previousErlOptions = $env:ELIXIR_ERL_OPTIONS
$gameExitCode = 0
try {
  # No BEAM console reader/break menu: the parent shell owns terminal input.
  $env:ELIXIR_ERL_OPTIONS = "$previousErlOptions -noinput +B d"
  $output = if ($Profile -eq 'dev') { 'debug' } else { $Profile }
  if (-not $env:WYRAM_CLIENT) { $env:WYRAM_CLIENT = Join-Path $root "native\target\$output\wyram_client.exe" }
  Invoke-WithDevelopmentPlugin -Package (Join-Path $root 'dist\wyram.wyrplug') -DataDirectory $data -Run {
    mix run scripts/run-game.exs
    $script:gameExitCode = $LASTEXITCODE
  }
} finally {
  $env:WYRAM_CLIENT = $previousClient
  $env:ELIXIR_ERL_OPTIONS = $previousErlOptions
}
if ($gameExitCode -ne 0) {
  [Console]::Error.WriteLine("Game exited with status $gameExitCode")
  exit $gameExitCode
}
