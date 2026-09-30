param([ValidateSet('dev','perf')][string]$Profile = 'perf', [string]$Output)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Output) { $Output = Join-Path $root ('bench\results\mesh-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json') }
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) { throw 'Choose a new output path; existing benchmarks are preserved' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
$previousOutput = $env:WYRAM_MESH_BENCH_OUTPUT
Push-Location $root
try {
  $env:WYRAM_MESH_BENCH_OUTPUT = $Output
  cargo test --manifest-path native/Cargo.toml -p wyram_client --profile $Profile --locked matched_mesh_benchmark -- --ignored --nocapture
  if ($LASTEXITCODE -ne 0) { throw 'Meshing benchmark failed' }
  $report = Get-Content -LiteralPath $Output -Raw | ConvertFrom-Json
  $commit = git rev-parse HEAD
  if ($LASTEXITCODE -ne 0) { throw 'Cannot record benchmark commit' }
  $dirty = [bool](git status --porcelain)
  if ($LASTEXITCODE -ne 0) { throw 'Cannot record benchmark worktree state' }
  $report | Add-Member -NotePropertyName commit -NotePropertyValue ([string]$commit)
  $report | Add-Member -NotePropertyName dirty_worktree -NotePropertyValue $dirty
  $report | Add-Member -NotePropertyName timestamp_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
  $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Output -Encoding UTF8
  Write-Host "Meshing benchmark: $Output"
} finally {
  $env:WYRAM_MESH_BENCH_OUTPUT = $previousOutput
  Pop-Location
}
