param([ValidateSet('dev','perf')][string]$Profile = 'dev',
  [ValidateSet('dev','perf')][string]$NativeProfile)
$ErrorActionPreference = 'Stop'
function Get-DevelopmentNativeHash([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
  finally { $algorithm.Dispose(); $stream.Dispose() }
}
$root = Split-Path -Parent $PSScriptRoot
if (-not $NativeProfile) { $NativeProfile = $Profile }
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
& (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
cargo build --manifest-path (Join-Path $root 'native\Cargo.toml') --profile $Profile --locked -p wyram_client
if ($LASTEXITCODE -ne 0) { throw 'Native client build failed' }
cargo build --manifest-path (Join-Path $root 'native\Cargo.toml') --profile $NativeProfile --locked -p wyram_nif
if ($LASTEXITCODE -ne 0) { throw 'Native generation build failed' }
$nativeOutput = if ($NativeProfile -eq 'dev') { 'debug' } else { $NativeProfile }
$nativeInput = Join-Path $root "native\target\$nativeOutput\wyram_nif.dll"
$nativeHash = Get-DevelopmentNativeHash $nativeInput
$nativeLibrary = "wyram_nif_${NativeProfile}_$nativeHash"
$nativeDirectory = Join-Path $root 'apps\wyram_engine\priv\native'
New-Item -ItemType Directory -Force -Path $nativeDirectory | Out-Null
$nativeArtifact = Join-Path $nativeDirectory "$nativeLibrary.dll"
if (Test-Path -LiteralPath $nativeArtifact) {
  if ((Get-DevelopmentNativeHash $nativeArtifact) -ne $nativeHash) {
    throw 'Native build artifact identity mismatch'
  }
} else {
  # Immutable names avoid overwriting a DLL used by another development game.
  Copy-Item -LiteralPath $nativeInput -Destination $nativeArtifact
}
$data = if ($env:WYRAM_DATA_DIR) { $env:WYRAM_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Wyram' }
$previousClient = $env:WYRAM_CLIENT
$previousErlOptions = $env:ELIXIR_ERL_OPTIONS
$previousNativeProfile = $env:WYRAM_NATIVE_PROFILE
$previousNativeLibrary = $env:WYRAM_NATIVE_LIBRARY
$previousNativeHash = $env:WYRAM_NATIVE_BUILD_HASH
$gameExitCode = 0
try {
  $env:WYRAM_NATIVE_PROFILE = $NativeProfile
  $env:WYRAM_NATIVE_LIBRARY = $nativeLibrary
  $env:WYRAM_NATIVE_BUILD_HASH = $nativeHash
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
  $env:WYRAM_NATIVE_PROFILE = $previousNativeProfile
  $env:WYRAM_NATIVE_LIBRARY = $previousNativeLibrary
  $env:WYRAM_NATIVE_BUILD_HASH = $previousNativeHash
}
if ($gameExitCode -ne 0) {
  [Console]::Error.WriteLine("Game exited with status $gameExitCode")
  exit $gameExitCode
}
