param([Parameter(Mandatory=$true)][ValidateSet('wyram','example','test_terrain','test_addon')][string]$Name)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plugin = if ($Name.StartsWith('test_')) { Join-Path $root "test\fixtures\plugins\$Name" } else { Join-Path $root "plugins\$Name" }
$stage = Join-Path $root ".tools\plugin-stage\$Name"
$destination = Join-Path $root "dist\$Name.wyrplug"
$archive = Join-Path $root "dist\$Name.zip"
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'ebin') | Out-Null
Get-ChildItem -LiteralPath (Join-Path $stage 'ebin') -File -Filter '*.beam' | Remove-Item -Force
Push-Location $plugin
try {
  mix deps.get
  if ($LASTEXITCODE -ne 0) { throw 'mix deps.get failed' }
  mix compile --warnings-as-errors
  if ($LASTEXITCODE -ne 0) { throw 'plugin compilation failed' }
} finally { Pop-Location }
Push-Location $plugin
try {
  mix run --no-compile --no-start (Join-Path $PSScriptRoot 'generate-plugin-manifest.exs') (Join-Path $stage 'manifest.json') (Join-Path $stage 'ebin')
  if ($LASTEXITCODE -ne 0) { throw 'plugin manifest generation failed' }
} finally { Pop-Location }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
$zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
try {
  [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $stage 'manifest.json'), 'manifest.json') | Out-Null
  foreach ($beam in Get-ChildItem -LiteralPath (Join-Path $stage 'ebin') -File -Filter '*.beam' | Sort-Object Name) {
    # ZIP names always use '/', including under Windows PowerShell 5.1.
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $beam.FullName, ('ebin/' + $beam.Name)) | Out-Null
  }
} finally { $zip.Dispose() }
Move-Item -LiteralPath $archive -Destination $destination
