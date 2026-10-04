param(
  [Parameter(Mandatory=$true)][string]$Directory,
  [switch]$AllowIncompleteDrain
)
$ErrorActionPreference = 'Stop'
function Get-FrameSummary {
  param([object[]]$Frames)
  if ($Frames.Count -eq 0) { throw 'Empty measurement phase' }
  $summary = @{ frames=$Frames.Count }
  foreach ($metric in @('frame_ms','redraw_cpu_ms','decode_ms','inbound_decode_ms','inbound_queue_max_ms','upload_cpu_ms','blended_prepare_cpu_ms','blended_collect_cpu_ms','blended_sort_cpu_ms','blended_write_cpu_ms','blended_quads','surface_acquire_ms','render_encode_cpu_ms','render_submit_cpu_ms','opaque_draws','opaque_vertices','gpu_render_ms')) {
    if ($Frames[0].PSObject.Properties.Name -notcontains $metric) { continue }
    $values = @($Frames | Where-Object { $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric } | Sort-Object)
    if ($values.Count -eq 0) { continue }
    $summary["${metric}_samples"] = $values.Count
    foreach ($p in @(50,95,99)) {
      $summary["${metric}_p$p"] = $values[[Math]::Max(0,[Math]::Ceiling($values.Count*$p/100)-1)]
    }
    $summary["${metric}_max"] = $values[-1]
  }
  foreach ($metric in @('worker_mesh_ms','uploaded_bytes','uploaded_meshes','stale_meshes','blended_write_bytes','inbound_wire_bytes')) {
    if ($Frames[0].PSObject.Properties.Name -contains $metric) {
      $summary["${metric}_sum"] = ($Frames | Measure-Object $metric -Sum).Sum
    }
  }
  $summary['dirty_max'] = ($Frames | Measure-Object dirty_chunks -Maximum).Maximum
  $summary['in_flight_max'] = ($Frames | Measure-Object in_flight -Maximum).Maximum
  return $summary
}
$reports = @(foreach ($run in Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name) {
  $phasePath = Join-Path $run.FullName 'phases.json'
  if (-not (Test-Path -LiteralPath $phasePath)) { continue }
  $markers = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json
  $metadata = Get-Content -LiteralPath (Join-Path $run.FullName 'metadata.json') -Raw | ConvertFrom-Json
  $frames = @(Get-Content -LiteralPath (Join-Path $run.FullName 'frames.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  $last = $frames[-1]
  if ($frames[0].build_profile -ne $metadata.profile) { throw "Client profile mismatch: $($run.Name)" }
  $adapterPath = Join-Path $run.FullName 'frames.adapter.json'
  $adapter = if (Test-Path -LiteralPath $adapterPath) { Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json } else { $null }
  if ($adapter -and $adapter.timestamp_queries -and -not ($frames | Where-Object { $null -ne $_.gpu_render_ms } | Select-Object -First 1)) {
    throw "GPU timing requested but no queries completed: $($run.Name)"
  }
  if ($last.loaded_chunks -ne $metadata.chunks -or $last.dropped_samples -ne 0) {
    throw "Missing chunks or dropped-sample capture: $($run.Name)"
  }
  if (($last.dirty_chunks -ne 0 -or $last.in_flight -ne 0) -and -not $AllowIncompleteDrain) {
    throw "Incomplete drain: $($run.Name). Use -AllowIncompleteDrain to report censoring explicitly."
  }
  $elapsed = 0.0; $firstClean = $null; $drainClean = $null; $drainStart = $null; $flightStart = $null
  for ($index=0; $index -lt $frames.Count; $index++) {
    $f = $frames[$index]
    if ($index -eq $markers.phases[2].persisted_frames) { $flightStart = $elapsed }
    if ($index -eq $markers.phases[3].persisted_frames) { $drainStart = $elapsed }
    $elapsed += $f.frame_ms
    if ($f.loaded_chunks -eq $metadata.chunks -and $f.dirty_chunks -eq 0 -and $f.in_flight -eq 0) {
      if ($null -eq $firstClean) { $firstClean = $elapsed }
      if ($null -ne $drainStart -and $null -eq $drainClean) { $drainClean = $elapsed - $drainStart }
    }
  }
  if ($null -eq $firstClean -or $firstClean -ge $flightStart) { throw "Initial residency did not finish before flight: $($run.Name)" }
  $phases = @{}
  foreach ($i in 0..3) {
    $start = [int]$markers.phases[$i].persisted_frames
    $end = [int]$markers.phases[$i+1].persisted_frames - 1
    $subset = @($frames[$start..$end])
    $left=0; $trim=0.0
    while ($left -lt $subset.Count -and $trim -lt 1000) { $trim += $subset[$left].frame_ms; $left++ }
    $right=$subset.Count-1; $trim=0.0
    while ($right -gt $left -and $trim -lt 1000) { $trim += $subset[$right].frame_ms; $right-- }
    $phases[$markers.phases[$i].phase] = Get-FrameSummary -Frames @($subset[$left..$right])
    # Synchronous coordinator calls are sampled by the route's next marker,
    # without trimming; unlike frame durations these are isolated call timings.
    if ($markers.phases[$i+1].PSObject.Properties.Name -contains 'client_call_us') {
      $calls = @($markers.phases[$i+1].client_call_us | Sort-Object)
      if ($calls.Count -gt 0) {
        foreach ($p in @(50,95,99)) { $phases[$markers.phases[$i].phase]["client_call_us_p$p"] = $calls[[Math]::Ceiling($calls.Count*$p/100)-1] }
        $phases[$markers.phases[$i].phase]['client_call_us_max'] = $calls[-1]
      }
    }
  }
  $censored = $null -eq $drainClean
  @{run=$run.Name; metadata=$metadata; adapter=$adapter; first_clean_ms=$firstClean; drain_clean_ms=$drainClean; drain_censored=$censored; drain_observed_ms=($elapsed-$drainStart); distance=($markers.phases[2].player.z-$markers.phases[3].player.z); phases=$phases; total=(Get-FrameSummary -Frames $frames); final=$last}
})
if ($reports.Count -eq 0) { throw 'No completed captures' }
$reports | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Directory 'summary.json') -Encoding UTF8
$reports | ForEach-Object { [pscustomobject]@{Run=$_.run; FirstCleanS=$_.first_clean_ms/1000; DrainCleanS=$(if ($_.drain_censored) { 'censored' } else { $_.drain_clean_ms/1000 }); FlightP95=$_.phases.flight.frame_ms_p95; FlightP99=$_.phases.flight.frame_ms_p99; FinalDirty=$_.final.dirty_chunks; FinalInFlight=$_.final.in_flight; Distance=$_.distance} } | Format-Table
