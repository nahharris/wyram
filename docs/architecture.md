# Architecture

The engine is an Elixir umbrella. `wyram_plugin_api` declares the public plugin contract; `wyram_engine` owns startup, plugin registration, the world and the native-client port. The official game is a separate compiled plugin. Native code is a Cargo workspace: `wyram_core` contains packed 16³ voxel chunks and deterministic terrain, `wyram_nif` exposes batch operations to Elixir, and `wyram_client` owns the winit window and wgpu renderer.

The world GenServer is authoritative for block edits and revisions. It holds generated chunk binaries and persists edited chunks. The client receives chunk snapshots through a length-prefixed JSON port protocol, keeps a visual replica, and sends edit intents. The first slice uses one world owner; splitting into region owners is the next scaling step. Native terrain generation is a dirty CPU NIF; rendering is outside the BEAM VM.

Current limitations are deliberate and measurable: the renderer builds visible faces rather than greedy meshes; initial streaming is synchronous; client movement and targeting are local and server validation of their coordinates is minimal; saves rewrite the edited-chunk snapshot on every edit; compiled plugins load at startup only. These are the next performance and integrity boundaries to address before claiming the targets in the plan.
