param([ValidateSet('dev','perf')][string]$Profile = 'perf',
  [ValidateRange(1,10)][int]$Rounds = 3, [string]$Output)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('.tools\generation-bench\' + [guid]::NewGuid().ToString('N'))
if (-not $Output) { $Output = Join-Path $data 'report.json' }
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) { throw 'Generation benchmark output already exists' }
. (Join-Path $PSScriptRoot 'development-plugin.ps1')
$variables = @('MIX_ENV', 'WYRAM_DATA_DIR', 'WYRAM_CLIENT', 'WYRAM_GAME_PLUGIN', 'WYRAM_CONTROL_PORT',
  'WYRAM_NATIVE_PROFILE', 'WYRAM_NATIVE_LIBRARY', 'WYRAM_NATIVE_BUILD_HASH',
  'WYRAM_GENERATION_BENCH_ROUNDS', 'WYRAM_GENERATION_BENCH_OUTPUT')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
Push-Location $root
try {
  $env:MIX_ENV = 'dev'
  $env:WYRAM_NATIVE_PROFILE = $null
  $env:WYRAM_NATIVE_LIBRARY = $null
  $env:WYRAM_NATIVE_BUILD_HASH = $null
  & (Join-Path $PSScriptRoot 'pack-plugin.ps1') -Name wyram
  cargo build --manifest-path native/Cargo.toml --profile $Profile --locked -p wyram_nif
  if ($LASTEXITCODE -ne 0) { throw 'Generation benchmark native build failed' }
  $nativeOutput = if ($Profile -eq 'dev') { 'debug' } else { $Profile }
  $nativeInput = Join-Path $root "native\target\$nativeOutput\wyram_nif.dll"
  $stream = [IO.File]::OpenRead($nativeInput)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
  finally { $algorithm.Dispose(); $stream.Dispose() }
  $library = "wyram_nif_${Profile}_$hash"
  $directory = Join-Path $root 'apps\wyram_engine\priv\native'
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $artifact = Join-Path $directory "$library.dll"
  if (-not (Test-Path -LiteralPath $artifact)) { Copy-Item -LiteralPath $nativeInput -Destination $artifact }
  $env:WYRAM_DATA_DIR = $data
  $env:WYRAM_CLIENT = 'C:\missing\wyram_client.exe'
  $env:WYRAM_GAME_PLUGIN = 'wyram'
  $env:WYRAM_CONTROL_PORT = $null
  $env:WYRAM_NATIVE_PROFILE = $Profile
  $env:WYRAM_NATIVE_LIBRARY = $library
  $env:WYRAM_NATIVE_BUILD_HASH = $hash
  $env:WYRAM_GENERATION_BENCH_ROUNDS = [string]$Rounds
  $env:WYRAM_GENERATION_BENCH_OUTPUT = $Output
  Invoke-WithDevelopmentPlugin -Package (Join-Path $root 'dist\wyram.wyrplug') -DataDirectory $data -Run {
    mix run bench/native_generation.exs
    if ($LASTEXITCODE -ne 0) { throw 'Generation benchmark failed' }
  }
} finally {
  foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
  Pop-Location
}
