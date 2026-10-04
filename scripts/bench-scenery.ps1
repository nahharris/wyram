param([ValidateRange(1,3)][int]$Rounds = 2, [switch]$Stationary,
    [ValidateSet('dev','perf')][string]$NativeProfile = 'perf',
    [ValidateRange(35,120)][int]$StationarySeconds = 35)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ('.tools\scenery-flight\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$variables = @('WYRAM_DATA_DIR', 'WYRAM_CLIENT', 'WYRAM_CLIENT_METRICS', 'WYRAM_FRAME_CAPTURE',
    'WYRAM_FRAME_CAPTURE_AFTER_MS', 'WYRAM_FLIGHT_BENCHMARK', 'WYRAM_SCENERY_PROTOCOL',
    'WYRAM_CHUNK_PROTOCOL', 'WYRAM_CONTROL_PORT', 'WYRAM_GAME_PLUGIN', 'WYRAM_BENCHMARK_STATIONARY',
    'WYRAM_BENCHMARK_STATIONARY_SECONDS')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:WYRAM_CLIENT = Join-Path $root 'native\target\perf\wyram_client.exe'
    $env:WYRAM_FLIGHT_BENCHMARK = '1'
    $env:WYRAM_CHUNK_PROTOCOL = '1'
    $env:WYRAM_CONTROL_PORT = $null
    $env:WYRAM_GAME_PLUGIN = 'wyram'
    $env:WYRAM_FRAME_CAPTURE_AFTER_MS = '92000'
    $env:WYRAM_BENCHMARK_STATIONARY = if ($Stationary) { '1' } else { $null }
    $env:WYRAM_BENCHMARK_STATIONARY_SECONDS = [string]$StationarySeconds
    if ($Stationary) {
        $env:WYRAM_CONTROL_PORT = '0'
        $env:WYRAM_FRAME_CAPTURE_AFTER_MS = [string](($StationarySeconds - 5) * 1000)
    }
    for ($round = 0; $round -lt $Rounds; $round++) {
        $order = if ($round % 2 -eq 0) { @(0,1) } else { @(1,0) }
        foreach ($distant in $order) {
            $name = if ($distant) { 'distant' } else { 'near' }
            $case = Join-Path $directory "$round-$name"
            New-Item -ItemType Directory -Force -Path $case | Out-Null
            $env:WYRAM_DATA_DIR = Join-Path $case 'data'
            $env:WYRAM_CLIENT_METRICS = Join-Path $case 'frames.jsonl'
            $env:WYRAM_FRAME_CAPTURE = Join-Path $case 'terrain.bmp'
            $env:WYRAM_SCENERY_PROTOCOL = [string]$distant
            Write-Host "Flight benchmark round=$round scenery=$distant output=$case"
            $positionJob = $null
            try {
                if ($Stationary) {
                    $positionJob = Start-Job -ArgumentList $env:WYRAM_DATA_DIR, (Join-Path $PSScriptRoot 'control.ps1') -ScriptBlock {
                        param($data, $control)
                        $ErrorActionPreference = 'Stop'
                        $deadline = [DateTime]::UtcNow.AddSeconds(120)
                        while ([DateTime]::UtcNow -lt $deadline) {
                            if (Test-Path -LiteralPath (Join-Path $data 'control.json')) {
                                $status = & $control -DataDir $data | ConvertFrom-Json
                                if ($status.client_connected -and $null -ne $status.player) {
                                    & $control -DataDir $data -Json '{"op":"teleport","x":672.5,"y":300.0,"z":672.5,"yaw":0.0,"pitch":-0.3}'
                                    return
                                }
                            }
                            Start-Sleep -Milliseconds 250
                        }
                        throw 'Stationary benchmark could not position the player'
                    }
                }
                & (Join-Path $PSScriptRoot 'dev.ps1') -Profile perf -NativeProfile $NativeProfile
                if ($LASTEXITCODE -ne 0) { throw "Flight benchmark failed: $case" }
                if ($positionJob) {
                    Receive-Job -Job $positionJob -Wait -ErrorAction Stop
                    if ($positionJob.State -ne 'Completed') { throw 'Stationary positioning failed' }
                }
                foreach ($output in @('terrain.bmp','frames.jsonl','frames.adapter.json','frames.native.json')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $case $output))) {
                        throw "Benchmark output missing: $output in $case"
                    }
                }
            } finally {
                if ($positionJob) { Stop-Job -Job $positionJob; Remove-Job -Job $positionJob }
            }
        }
    }
} finally {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
Write-Host "Flight benchmark captures: $directory"
