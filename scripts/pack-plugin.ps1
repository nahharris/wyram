param([Parameter(Mandatory=$true)][ValidateSet('official','example','test_terrain','test_addon')][string]$Name)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plugin = if ($Name.StartsWith('test_')) { Join-Path $root "test\fixtures\plugins\$Name" } else { Join-Path $root "plugins\$Name" }
$stage = Join-Path $root ".tools\plugin-stage\$Name"
$destination = Join-Path $root "dist\$Name.wyrplug"
$archive = Join-Path $root "dist\$Name.zip"
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'ebin') | Out-Null
Copy-Item -LiteralPath (Join-Path $plugin 'manifest.json') -Destination (Join-Path $stage 'manifest.json') -Force
Push-Location $plugin
try {
  mix deps.get
  if ($LASTEXITCODE -ne 0) { throw 'mix deps.get failed' }
  mix compile --warnings-as-errors
  if ($LASTEXITCODE -ne 0) { throw 'plugin compilation failed' }
} finally { Pop-Location }
Get-ChildItem -LiteralPath (Join-Path $plugin '_build\dev\lib') -Recurse -Filter 'Elixir.WyramMods.*.beam' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage "ebin\$($_.Name)") -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
Compress-Archive -Path (Join-Path $stage 'manifest.json'),(Join-Path $stage 'ebin') -DestinationPath $archive -Force
Move-Item -LiteralPath $archive -Destination $destination
