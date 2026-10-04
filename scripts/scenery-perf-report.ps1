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
    $loading = @()
    if ($frames[0].PSObject.Properties.Name -contains 'scenery_epoch') {
        $loading = @($frames | Where-Object { $_.scenery_planned_tiles -gt 0 } |
            Group-Object scenery_epoch | ForEach-Object {
                $samples = $_.Group
                $planned = $samples[-1].scenery_planned_tiles
                $received = $samples | Where-Object { $_.scenery_received_tiles -eq $planned } | Select-Object -First 1
                $ready = $samples | Where-Object { $_.scenery_ready_tiles -eq $planned } | Select-Object -First 1
                @{ epoch = $samples[0].scenery_epoch; planned_tiles = $planned;
                    first_plan_ms = $samples[0].benchmark_elapsed_ms;
                    first_all_received_ms = if ($received) { $received.benchmark_elapsed_ms } else { $null };
                    first_all_ready_ms = if ($ready) { $ready.benchmark_elapsed_ms } else { $null };
                    final_received_tiles = $samples[-1].scenery_received_tiles;
                    final_ready_tiles = $samples[-1].scenery_ready_tiles }
            })
    }
    $nativePath = Join-Path $case.FullName 'frames.native.json'
    $native = if (Test-Path -LiteralPath $nativePath) { Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json } else { $null }
    @{ name = $case.Name; frames = $frames.Count; adapter = (Get-Content -LiteralPath (Join-Path $case.FullName 'frames.adapter.json') -Raw | ConvertFrom-Json);
        native = $native;
        profile = $frames[0].build_profile; opt_level = $frames[0].opt_level;
        dropped_samples = $frames[-1].dropped_samples; maxima = $maxima; phases = @($phases);
        loading = $loading;
        final_degraded_ready_tiles = $frames[-1].scenery_degraded_ready_tiles;
        image = (Join-Path $case.FullName 'terrain.bmp') }
}
$report | ConvertTo-Json -Depth 12
