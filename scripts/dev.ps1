$ErrorActionPreference = 'Stop'
mix run --no-halt
if ($LASTEXITCODE -ne 0) { throw 'Game exited with an error' }
