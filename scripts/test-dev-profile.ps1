$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$previousData = $env:WYRAM_DATA_DIR
$previousClient = $env:WYRAM_CLIENT
$previousErlOptions = $env:ELIXIR_ERL_OPTIONS
$previousNativeProfile = $env:WYRAM_NATIVE_PROFILE
$previousNativeLibrary = $env:WYRAM_NATIVE_LIBRARY
$previousNativeHash = $env:WYRAM_NATIVE_BUILD_HASH
$mixExecutable = (Get-Command mix -CommandType Application | Select-Object -First 1).Source
$probe = [pscustomobject]@{Calls=0}
function mix {
  if ($args.Count -eq 2 -and $args[0] -eq 'run' -and $args[1] -eq 'scripts/run-game.exs') {
    # Exercise real packaging/build/staging, replacing only the indefinite game run.
    if ($env:WYRAM_CLIENT -ne $expectedClient) { throw 'Launcher selected the wrong native profile' }
    if ($env:WYRAM_NATIVE_PROFILE -ne $expectedNativeProfile) { throw 'Launcher selected the wrong generation profile' }
    if (-not (Test-Path -LiteralPath $expectedPlugin)) { throw 'Launcher did not stage the plugin' }
    if ($env:ELIXIR_ERL_OPTIONS -notmatch '(^|\s)-noinput($|\s)') { throw 'Launcher enabled the BEAM terminal reader' }
    if ($env:ELIXIR_ERL_OPTIONS -notmatch '\+B\s+d($|\s)') { throw 'Launcher enabled the BEAM break menu' }
    $probe.Calls += 1
    & $mixExecutable run --no-start (Join-Path $PSScriptRoot 'test-native-profile.exs') $expectedNativeProfile
    if ($LASTEXITCODE -ne 0) { throw 'Loaded generation profile does not match the launcher' }
    $global:LASTEXITCODE = 0
  } else { & $mixExecutable @args }
}
try {
  foreach ($profile in @('dev', 'perf')) {
    $env:WYRAM_DATA_DIR = Join-Path $root ('.tools\dev-profile-test\' + [guid]::NewGuid().ToString('N'))
    $env:WYRAM_CLIENT = $null
    $probe.Calls = 0
    $output = if ($profile -eq 'dev') { 'debug' } else { 'perf' }
    $expectedClient = Join-Path $root "native\target\$output\wyram_client.exe"
    $expectedNativeProfile = $profile
    $expectedPlugin = Join-Path $env:WYRAM_DATA_DIR 'plugins\wyram.wyrplug'
    & (Join-Path $PSScriptRoot 'dev.ps1') -Profile $profile
    if (Test-Path -LiteralPath $expectedPlugin) { throw 'Launcher left the staged plugin installed' }
    if ($env:WYRAM_CLIENT) { throw 'Launcher did not restore the client environment' }
    if ($env:ELIXIR_ERL_OPTIONS -ne $previousErlOptions) { throw 'Launcher did not restore Erlang options' }
    if ($env:WYRAM_NATIVE_PROFILE -ne $previousNativeProfile -or $env:WYRAM_NATIVE_LIBRARY -ne $previousNativeLibrary -or $env:WYRAM_NATIVE_BUILD_HASH -ne $previousNativeHash) { throw 'Launcher did not restore generation environment' }
    if ($probe.Calls -ne 1) { throw 'Launcher did not invoke the game exactly once' }
  }
  $env:WYRAM_DATA_DIR = Join-Path $root ('.tools\dev-profile-test\' + [guid]::NewGuid().ToString('N'))
  $env:WYRAM_CLIENT = $null
  $expectedClient = Join-Path $root 'native\target\perf\wyram_client.exe'
  $expectedNativeProfile = 'dev'
  $expectedPlugin = Join-Path $env:WYRAM_DATA_DIR 'plugins\wyram.wyrplug'
  $probe.Calls = 0
  & (Join-Path $PSScriptRoot 'dev.ps1') -Profile perf -NativeProfile dev
  if ($probe.Calls -ne 1) { throw 'Mixed profile comparison did not run' }
  $env:WYRAM_CLIENT = 'C:\missing\custom-client.exe'
  $expectedClient = $env:WYRAM_CLIENT
  $expectedNativeProfile = 'dev'
  $probe.Calls = 0
  & (Join-Path $PSScriptRoot 'dev.ps1') -Profile dev
  if ($probe.Calls -ne 1 -or $env:WYRAM_CLIENT -ne $expectedClient) { throw 'Launcher did not preserve explicit client override' }
} finally {
  $env:WYRAM_DATA_DIR = $previousData
  $env:WYRAM_CLIENT = $previousClient
  $env:ELIXIR_ERL_OPTIONS = $previousErlOptions
  $env:WYRAM_NATIVE_PROFILE = $previousNativeProfile
  $env:WYRAM_NATIVE_LIBRARY = $previousNativeLibrary
  $env:WYRAM_NATIVE_BUILD_HASH = $previousNativeHash
}
Write-Host 'Debug and optimized development launchers passed'
