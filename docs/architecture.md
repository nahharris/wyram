# Architecture

The engine is an Elixir umbrella. `wyram_plugin_api` declares the public plugin contract; `wyram_engine` owns startup, plugin registration, the world and the native-client port. The Wyram game is a separate compiled plugin. Native code is a Cargo workspace: `wyram_core` contains packed 16³ voxel chunks and deterministic terrain, `wyram_nif` exposes batch operations to Elixir, and `wyram_client` owns the winit window and wgpu renderer.

Each region GenServer owns the packed chunks in a 4 by 4 chunk-column area. World operations route directly to the region process through a Registry; the World GenServer serializes durable edits to the save file. Regions load edited chunks when they start, so a crashed region can recover from the saved state. The client receives chunk snapshots through a length-prefixed JSON port protocol, keeps a visual replica, and sends edit intents. Native terrain generation is a dirty CPU NIF; rendering is outside the BEAM VM.

Current limitations are deliberate and measurable: the renderer builds visible faces rather than greedy meshes; initial streaming is synchronous; client movement and targeting are local and server validation of their coordinates is minimal; the World save writer still serializes all edits and rewrites the edited-chunk snapshot on every edit; compiled plugins load at startup only. These are the next performance and integrity boundaries to address before claiming the targets in the plan.

Run `mise exec -- mix run bench/regions.exs` after setup to compare serial and four-region concurrent chunk generation on the same machine. This measures generation throughput, not frame time or a full-game speedup. Benchmark output is deliberately not a CI threshold because CPU topology and runner load vary.
