$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\dev-plugin-test\' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $root 'dist\wyram.wyrplug'
$installed = Join-Path $data 'plugins\wyram.wyrplug'

Invoke-WithDevelopmentPlugin -Package $package -DataDirectory $data -Run {
  if (-not (Test-Path -LiteralPath $installed)) { throw 'Development plugin was not staged' }
}
if (Test-Path -LiteralPath $installed) { throw 'Temporary plugin remained after successful exit' }

[IO.File]::WriteAllText($installed, 'previous installed plugin')
$previous = [IO.File]::ReadAllText($installed)
try {
  Invoke-WithDevelopmentPlugin -Package $package -DataDirectory $data -Run {
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($installed)) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($package))) {
      throw 'Development package did not replace installed plugin'
    }
    throw 'simulated game failure'
  }
  throw 'Game failure was swallowed'
} catch {
  if ($_.Exception.Message -ne 'simulated game failure') { throw }
}
if ([IO.File]::ReadAllText($installed) -ne $previous) { throw 'Installed plugin was not restored after failure' }
Remove-Item -LiteralPath $installed
try {
  Invoke-WithDevelopmentPlugin -Package $package -DataDirectory $data -Run { throw 'simulated game failure' }
} catch {
  if ($_.Exception.Message -ne 'simulated game failure') { throw }
}
if (Test-Path -LiteralPath $installed) { throw 'Temporary plugin remained after failed exit' }

$oldData = $env:WYRAM_DATA_DIR
$oldClient = $env:WYRAM_CLIENT
try {
  $env:WYRAM_DATA_DIR = $data
  $env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
  Invoke-WithDevelopmentPlugin -Package $package -DataDirectory $data -Run {
    mix run (Join-Path $PSScriptRoot 'test-wyram-smoke.exs')
    if ($LASTEXITCODE -ne 0) { throw 'Development plugin startup failed' }
  }
} finally {
  $env:WYRAM_DATA_DIR = $oldData
  $env:WYRAM_CLIENT = $oldClient
}
if (Test-Path -LiteralPath $installed) { throw 'Temporary plugin remained after real engine startup' }
Write-Host 'Development plugin staging and cleanup passed'
