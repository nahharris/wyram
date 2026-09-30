param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$samples = @([IO.File]::ReadLines([IO.Path]::GetFullPath($Path)) | ForEach-Object { $_ | ConvertFrom-Json })
if ($samples.Count -eq 0) { throw 'Capture has no frame samples' }
foreach ($metric in @('frame_ms', 'redraw_cpu_ms', 'decode_ms', 'worker_mesh_ms', 'upload_cpu_ms')) {
  $values = @($samples | ForEach-Object { [double]($_.$metric) } | Sort-Object)
  $p50 = $values[[Math]::Max(0, [Math]::Ceiling($values.Count * 0.50) - 1)]
  $p95 = $values[[Math]::Max(0, [Math]::Ceiling($values.Count * 0.95) - 1)]
  $p99 = $values[[Math]::Max(0, [Math]::Ceiling($values.Count * 0.99) - 1)]
  Write-Host ('{0}: p50={1:F3} p95={2:F3} p99={3:F3} max={4:F3} ms' -f $metric, $p50, $p95, $p99, $values[-1])
}
Write-Host ("Frames: {0}; dropped samples: {1}" -f $samples.Count, $samples[-1].dropped_samples)
if ($samples[-1].PSObject.Properties.Name -contains 'outbound_sent') {
  $last = $samples[-1]
  Write-Host ('Outbound: sent={0}; queued={1}; coalesced poses={2}; lifetime queue max={3:F3} ms; write max={4:F3} ms' -f $last.outbound_sent, $last.outbound_queued, $last.outbound_coalesced_poses, $last.outbound_queue_max_ms, $last.outbound_write_max_ms)
}
