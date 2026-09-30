$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ('.tools/dev-exit-test/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $directory | Out-Null
$client = Join-Path $directory 'exit-client.exe'
rustc (Join-Path $root 'test/fixtures/native-client-exit.rs') -o $client
if ($LASTEXITCODE -ne 0) { throw 'Exit fixture build failed' }
foreach ($status in @(0, 7, -1)) {
  $data = Join-Path $directory "case-$status"
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = 'powershell.exe'
  $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File scripts/dev.ps1'
  $info.WorkingDirectory = $root
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.EnvironmentVariables['WYRAM_DATA_DIR'] = $data
  $info.EnvironmentVariables['WYRAM_CLIENT'] = if ($status -eq -1) { Join-Path $directory 'missing.exe' } else { $client }
  $info.EnvironmentVariables['WYRAM_TEST_CLIENT_STATUS'] = [string]$status
  $info.EnvironmentVariables.Remove('WYRAM_CONTROL_PORT')
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(60000)) {
    & taskkill.exe /PID $process.Id /T /F | Out-Null
    throw "Development launcher hung after native exit ($status)"
  }
  $output = $stdout.Result + $stderr.Result
  if (($status -eq 0) -ne ($process.ExitCode -eq 0)) { throw "Incorrect launcher status: $output" }
  if ($status -eq 7 -and $process.ExitCode -ne 7) { throw "Native failure status was not propagated: $output" }
  if ($status -eq 0 -and $output -match 'warning.*Native client exited') { throw 'Normal close logged a warning' }
  if (Test-Path -LiteralPath (Join-Path $data 'plugins/wyram.wyrplug')) { throw 'Launcher failed to clean up its staged plugin' }
  $process.Dispose()
}
Write-Host 'Development launcher exits and cleanup passed (normal, failed, missing client)'
