$ErrorActionPreference = 'Stop'
$env:WYRAM_CONTROL_PORT = '0'
& (Join-Path $PSScriptRoot 'dev.ps1')
