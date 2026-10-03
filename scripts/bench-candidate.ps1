param(
  [Parameter(Mandatory=$true)][string]$BaselineDirectory,
  [Parameter(Mandatory=$true)][string]$CandidateDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [ValidateRange(1,10)][int]$Rounds = 3,
  [ValidateSet('desktop','worldgen')][string]$Workload = 'desktop'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Get-Checksum {
  param([string]$Path)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','') }
  finally { $algorithm.Dispose() }
}
$snapshots = @{
  baseline = [IO.Path]::GetFullPath($BaselineDirectory)
  candidate = [IO.Path]::GetFullPath($CandidateDirectory)
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory' }
foreach ($snapshot in $snapshots.Values) {
  foreach ($file in @('metadata.json','wyram.wyrplug','native\wyram_client.exe','mix-build\dev\lib\wyram_engine\ebin\wyram_engine.app')) {
    if (-not (Test-Path -LiteralPath (Join-Path $snapshot $file))) { throw "Snapshot missing $file" }
  }
}
$variables = @('MIX_ENV','MIX_BUILD_PATH','WYRAM_DATA_DIR','WYRAM_CLIENT','WYRAM_CLIENT_METRICS','WYRAM_FLIGHT_PHASES','WYRAM_FLIGHT_HEIGHT_OFFSET','WYRAM_CONTROL_PORT','ELIXIR_ERL_OPTIONS','WYRAM_STREAM_RESPONSIVENESS','WYRAM_FRUSTUM_CULLING','WYRAM_CHUNK_PROTOCOL','WYRAM_MESH_UPLOAD_LIMIT','WYRAM_ROUTE_STARTUP_MS','WYRAM_ROUTE_DRAIN_MS')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
Push-Location $root
try {
  foreach ($round in 0..($Rounds - 1)) {
    $order = if ($round % 2 -eq 0) { @('baseline','candidate') } else { @('candidate','baseline') }
    foreach ($variant in $order) {
      $snapshot = $snapshots[$variant]
      $run = Join-Path $OutputDirectory "$variant-$round"
      New-Item -ItemType Directory -Path "$run\data\plugins" -Force | Out-Null
      Copy-Item -LiteralPath "$snapshot\wyram.wyrplug" -Destination "$run\data\plugins\wyram.wyrplug"
      Copy-Item -LiteralPath "$snapshot\metadata.json" -Destination "$run\metadata.json"
      $metadata = Get-Content -LiteralPath "$snapshot\metadata.json" -Raw | ConvertFrom-Json
      if ((Get-Checksum "$snapshot\native\wyram_client.exe") -ne $metadata.client_sha256) { throw 'Client differs from snapshot metadata' }
      $env:WYRAM_FRUSTUM_CULLING = if ($metadata.PSObject.Properties.Name -contains 'frustum_culling') { [string]$metadata.frustum_culling } else { $null }
      $env:WYRAM_CHUNK_PROTOCOL = if ($metadata.PSObject.Properties.Name -contains 'chunk_protocol') { [string]$metadata.chunk_protocol } else { $null }
      $env:WYRAM_MESH_UPLOAD_LIMIT = if ($metadata.PSObject.Properties.Name -contains 'mesh_upload_limit') { [string]$metadata.mesh_upload_limit } else { $null }
      $env:MIX_ENV = 'dev'
      $env:MIX_BUILD_PATH = "$snapshot\mix-build\dev"
      $env:WYRAM_DATA_DIR = "$run\data"
      $env:WYRAM_CLIENT = if ($Workload -eq 'desktop') { "$snapshot\native\wyram_client.exe" } else { 'C:\missing\wyram_client.exe' }
      $env:WYRAM_CLIENT_METRICS = "$run\frames.jsonl"
      $env:WYRAM_FLIGHT_PHASES = "$run\phases.json"
      $env:WYRAM_FLIGHT_HEIGHT_OFFSET = '48'
      $env:WYRAM_CONTROL_PORT = $null
      $env:ELIXIR_ERL_OPTIONS = '-noinput +B d'
      $route = if ($Workload -eq 'desktop') { 'bench/chunk_route.exs' } else { 'bench/worldgen_reuse.exs' }
      mix run --no-compile --no-deps-check $route
      if ($LASTEXITCODE -ne 0) { throw "Route failed: $variant round $round" }
      $phases = Get-Content -LiteralPath "$run\phases.json" -Raw | ConvertFrom-Json
      $metadata = Get-Content -LiteralPath "$run\metadata.json" -Raw | ConvertFrom-Json
      if ($phases.nif_sha256 -ne $metadata.nif_sha256) { throw 'Loaded NIF differs from the snapshot metadata' }
      if ($Workload -eq 'worldgen') {
        if ($null -eq $inventoryDigest) { $inventoryDigest = $phases.digest }
        if ($phases.digest -ne $inventoryDigest -or $phases.chunks -ne $metadata.chunks) { throw 'Worldgen output parity failed' }
      }
    }
  }
} finally {
  foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
  Pop-Location
}
