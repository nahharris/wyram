$ErrorActionPreference = 'Stop'
$env:WYRAM_CONTROL_PORT = '0'
mix run --no-halt
if ($LASTEXITCODE -ne 0) { throw 'Game exited with an error' }
