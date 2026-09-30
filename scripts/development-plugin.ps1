function Invoke-WithDevelopmentPlugin {
  param(
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$DataDirectory,
    [Parameter(Mandatory=$true)][scriptblock]$Run
  )
  $directory = Join-Path $DataDirectory 'plugins'
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  # Hold an exclusive lock so two dev sessions cannot overwrite each other's backup.
  $lock = [IO.File]::Open((Join-Path $directory '.wyram-dev.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $target = Join-Path $directory 'wyram.wyrplug'
    $previousExists = Test-Path -LiteralPath $target
    if ($previousExists) { $previousBytes = [IO.File]::ReadAllBytes($target) }
    try {
      Copy-Item -LiteralPath $Package -Destination $target -Force
      & $Run
    } finally {
      if ($previousExists) {
        [IO.File]::WriteAllBytes($target, $previousBytes)
      } elseif (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
      }
    }
  } finally { $lock.Dispose() }
}
