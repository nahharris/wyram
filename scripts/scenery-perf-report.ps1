param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference = 'Stop'
function Quantiles($samples, [string]$metric) {
    $values = @($samples | ForEach-Object { if ($null -ne $_.$metric) { [double]($_.$metric) } } | Sort-Object)
    if ($values.Count -eq 0) { return $null }
    return @{ count = $values.Count; p50 = $values[[Math]::Ceiling($values.Count * 0.50)-1];
        p95 = $values[[Math]::Ceiling($values.Count * 0.95)-1];
        p99 = $values[[Math]::Ceiling($values.Count * 0.99)-1]; max = $values[-1] }
}
$report = foreach ($case in Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name) {
    $path = Join-Path $case.FullName 'frames.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $frames = @([IO.File]::ReadLines($path) | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    $phases = foreach ($phase in @('settle','rise','outbound','return','settled','stationary')) {
        $samples = @($frames | Where-Object { $_.benchmark_phase -eq $phase })
        if ($phase -eq 'stationary') {
            $samples = @($samples | Where-Object { $_.benchmark_elapsed_ms -ge 10000 })
        }
        if ($samples.Count -eq 0) { continue }
        $metrics = @{}
        foreach ($metric in @('frame_ms','redraw_cpu_ms','gpu_render_ms','worker_mesh_ms',
            'upload_cpu_ms','blended_prepare_cpu_ms','surface_acquire_ms','scenery_update_cpu_ms',
            'scenery_worker_mesh_ms','scenery_upload_cpu_ms')) {
            $metrics[$metric] = Quantiles $samples $metric
        }
        @{ phase = $phase; frames = $samples.Count; metrics = $metrics;
            flight_frames = @($samples | Where-Object { $_.approved_flight }).Count;
            from = $samples[0].observer_position; to = $samples[-1].observer_position }
    }
    $maxima = @{}
    foreach ($metric in @('scenery_in_flight','scenery_uploads','scenery_ready_tiles',
        'scenery_selected_tiles','scenery_failed_tiles','scenery_mesh_reserved_bytes',
        'scenery_opaque_draws','scenery_opaque_vertices','loaded_chunks','inbound_queue_max_ms')) {
        $maxima[$metric] = ($frames | Measure-Object -Property $metric -Maximum).Maximum
    }
    @{ name = $case.Name; frames = $frames.Count; adapter = (Get-Content -LiteralPath (Join-Path $case.FullName 'frames.adapter.json') -Raw | ConvertFrom-Json);
        profile = $frames[0].build_profile; opt_level = $frames[0].opt_level;
        dropped_samples = $frames[-1].dropped_samples; maxima = $maxima; phases = @($phases);
        image = (Join-Path $case.FullName 'terrain.bmp') }
}
$report | ConvertTo-Json -Depth 12
