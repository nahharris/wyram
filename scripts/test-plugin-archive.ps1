$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($name in @('test_terrain', 'test_addon', 'wyram')) {
  $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $root "dist\$name.wyrplug"))
  try {
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName.Contains('\')) { throw "Plugin $name contains a nonportable ZIP path: $($entry.FullName)" }
    }
    if (-not ($archive.Entries.FullName -contains 'manifest.json')) { throw "Plugin $name is missing its manifest" }
    if (-not ($archive.Entries.FullName -match '^ebin/[^/]+\.beam$')) { throw "Plugin $name is missing canonical BEAM paths" }
  } finally { $archive.Dispose() }
}
Write-Host 'Plugin archive paths are portable'
