$ErrorActionPreference = 'Stop'
$required = @('erl', 'elixir', 'cargo', 'rustc')
foreach ($tool in $required) {
  $found = Get-Command $tool -ErrorAction SilentlyContinue
  if ($null -eq $found) { throw "Missing tool: $tool" }
  Write-Host "$tool -> $($found.Source)"
}
elixir --version
cargo --version
rustc --version
Write-Host 'Windows native build tools detected.'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools not found' }
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'MSVC C++ tools not found' }
Write-Host "MSVC -> $installation"
