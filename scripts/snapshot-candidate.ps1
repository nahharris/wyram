param(
  [Parameter(Mandatory=$true)][string]$Directory,
  [ValidateSet('debug','perf')][string]$Profile = 'perf',
  [Parameter(Mandatory=$true)][string]$Nif,
  [ValidateSet('debug','release')][string]$EngineProfile = 'debug',
  [ValidateSet(0,1)][int]$FrustumCulling = 1,
  [ValidateSet(0,1)][int]$ChunkProtocol = 1,
  [ValidateRange(1,8)][int]$MeshUploadLimit = 8
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$destination = [IO.Path]::GetFullPath($Directory)
if (Test-Path -LiteralPath $destination) { throw 'Choose a new immutable snapshot directory' }
$client = Join-Path $root "native\target\$Profile\wyram_client.exe"
$build = Join-Path $root '_build\dev\lib'
$package = Join-Path $root 'dist\wyram.wyrplug'
$nifPath = [IO.Path]::GetFullPath($Nif)
foreach ($path in @($client,$package,$nifPath,(Join-Path $build 'wyram_engine\ebin\wyram_engine.app'))) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Snapshot input missing: $path" }
}
function Get-Checksum {
  param([string]$Path)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','') }
  finally { $algorithm.Dispose() }
}
New-Item -ItemType Directory -Path "$destination\native","$destination\mix-build\dev" -Force | Out-Null
Copy-Item -LiteralPath $build -Destination "$destination\mix-build\dev" -Recurse
Copy-Item -LiteralPath $client -Destination "$destination\native\wyram_client.exe"
Copy-Item -LiteralPath $nifPath -Destination "$destination\native\wyram_nif.dll"
Copy-Item -LiteralPath $nifPath -Destination "$destination\mix-build\dev\lib\wyram_engine\priv\native\wyram_nif.dll" -Force
Copy-Item -LiteralPath $package -Destination "$destination\wyram.wyrplug"
$commit = git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify snapshot commit' }
@{commit=$commit; profile=$Profile; engine_profile=$EngineProfile; columns=81; chunks=2592;
  client_sha256=(Get-Checksum $client); nif_sha256=(Get-Checksum $nifPath);
  frustum_culling=$FrustumCulling; chunk_protocol=$ChunkProtocol; mesh_upload_limit=$MeshUploadLimit
} | ConvertTo-Json | Set-Content -LiteralPath "$destination\metadata.json" -Encoding UTF8
Write-Output "Snapshot created: $destination"
