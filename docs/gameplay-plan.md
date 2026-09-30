# Gameplay and reusable characters

[Roadmap #9](https://github.com/nahharris/wyram/issues/9) tracks richer voxel movement and character presentation. Each slice ships from an isolated worktree through a PR to `main`, with `mise run check`, `mise run test` and Windows CI. Existing work in another checkout must stay separate.

## Feasibility and delivery order

Walking, Ctrl-running and Space-jumping already exist. Their tuning was hard-coded in the native client, whose original frame-step collision checks sampled body corners. The authority slice replaces that solver with fixed-step Elixir state and packed swept-AABB queries. There are no variable posture bodies, fluid semantics, character models, skeletons, animation clips or external cameras. A continuous jump apex of 1.225 blocks does not establish that the existing collision solver reliably clears a one-block obstacle.

| Work | Readiness and dependency | Issue |
| --- | --- | --- |
| Public character profiles and Elixir walk/run policy | Implement first; preserve existing controls and tuning | [#10](https://github.com/nahharris/wyram/issues/10) |
| Fixed-step character authority and batched swept collision | Implemented foundation; explicit unknown-terrain handling | [#11](https://github.com/nahharris/wyram/issues/11) |
| Sneaking | Next feature after authority/body clearance; reduced height, slow movement, safe ledges | [#12](https://github.com/nahharris/wyram/issues/12) |
| Prone crawling | Requires posture clearance and sneaking | [#13](https://github.com/nahharris/wyram/issues/13) |
| Guaranteed one-block jumping | Requires fixed-step collision; test clearance and landing across render schedules | [#14](https://github.com/nahharris/wyram/issues/14) |
| Climbing/mantling up to three blocks | Requires swept ledge queries, clearance and traversal phases | [#15](https://github.com/nahharris/wyram/issues/15) |
| Floor sliding | Requires running, low posture, swept movement and friction | [#16](https://github.com/nahharris/wyram/issues/16) |
| Wall sliding | Requires authoritative airborne contact and controlled descent | [#17](https://github.com/nahharris/wyram/issues/17) |
| Swimming and diving | Deferred until public fluid semantics and water presentation exist | [#18](https://github.com/nahharris/wyram/issues/18) |
| Four-direction rolling | Requires swept action movement, clearance and interruption rules | [#19](https://github.com/nahharris/wyram/issues/19) |
| Reusable body, rig and models | Design alongside movement; demonstrate a second character | [#20](https://github.com/nahharris/wyram/issues/20) |
| Reusable animations | Requires rig and approved character state/phase snapshots | [#21](https://github.com/nahharris/wyram/issues/21) |
| Third-person and front-facing cameras | Requires visible model and body coordinates independent of the camera | [#22](https://github.com/nahharris/wyram/issues/22) |

The requested second-person camera is provisionally interpreted as a front-facing external view looking back at the character. Confirm that meaning before the camera implementation. The movement direction, targeting origin and edit reach must have explicit rules when switching views.

## First slice: shared locomotion policy

`Wyram.Character.Profile` is a public, immutable Elixir value with walk/run speed, jump impulse, gravity and terminal fall speed. Defaults retain 5/9 blocks per second, a 7-block-per-second jump impulse, gravity 20 and terminal speed 25. Values must be positive numbers no greater than 100; running must be at least as fast as walking. The bound is an API validation limit, not a guarantee that the current collision solver supports every tuning safely.

The game plugin can implement the optional `Wyram.Plugin.player_profile/0` callback. The engine takes the profile from the same plugin supplying its active terrain; add-ons cannot replace it merely by defining the callback. Plugins compiled without the optional callback retain the default profile and API version 1. A future NPC can use its own profile with the same pure `Profile.motion/2` policy, without a player-specific process or renderer input dependency.

The engine sends approved walking motion in `hello`. Ctrl press/release sends a boolean `movement_intent`; Elixir selects walk/run speed and returns a `motion` snapshot. Native prediction consumes that snapshot instead of selecting its own speeds. A change is sent immediately at the next frame, independently of the 200 ms pose-report interval. The existing outbound worker retains at most one pending mode intent; pipe writes stay outside the renderer. Mode changes take effect when the engine response arrives, so existing synchronous chunk streaming can add input latency under load; [streaming issue #4](https://github.com/nahharris/wyram/issues/4) remains relevant.

Focus loss, Escape and teleports clear held input and publish a walking intent when needed. Teleports also reset the engine's mode. This slice changes policy ownership and reuse; it adds no crouch/crawl body, stamina, invulnerability or new traversal action. Position, grounded detection and jump triggering still use the existing local solver and client pose reports are still minimally validated. Issue #11 is required before claiming full gameplay authority or introducing the more involved traversal states.

## Reuse boundary

Elixir owns character capabilities, action eligibility, transitions and gameplay displacement. Region actors or a bounded simulation owner hold dense character state; no process per block or character. Native code supplies batched packed-voxel queries and performs prediction, rendering, rig evaluation, clip blending and cameras. Never make the renderer wait on a GenServer or native pipe write.

Use feet-space collision bodies independent of eye position, meshes and rigs. Character profiles specify capabilities/tuning; a future animation mapping consumes approved locomotion/posture/action phases. Root motion cannot silently become a second gameplay authority. Model import and rig conventions must work for a second character. Build outputs and downloaded tools remain ignored; original editable source assets need an explicit source/runtime pipeline.
## Authoritative character foundation

Issue #11 replaces client pose reports with bounded `input` packets carrying sequence and epoch. Elixir normalizes direction, selects profile speed, advances 20 ms steps, gates jumps on grounded input edges and applies gravity. Region actors return immutable chunk binaries grouped by owner; one dirty CPU NIF resolves each body-query batch. Query limits are 256 bodies, 4096 chunks, 4096 candidate cells per body, positions within one million blocks and displacements within eight blocks per axis. Missing terrain or failed acquisition explicitly freezes the body as unavailable. Current non-air blocks are solid; fluid semantics remain deferred.

Standing bodies use feet coordinates, radius 0.28, height 1.8 and eye offset 1.62. Eye coordinates remain in control snapshots for compatibility. The native client reconciles epoch/sequence-tagged state and predicts at most 40 ms of approved velocity against its visual replica. It does not choose speed, gravity, jump eligibility or position from raw keys. Input is coalesced in one reserved outbound slot; 100 ms heartbeats keep it live, and the engine expires movement after 250 ms without accepted input. Teleports check clearance, reset motion/input and use a new epoch. Owner restarts also publish a new epoch so old snapshots and inputs cannot displace the reset body.

The shared owner schedules one next tick and does not accumulate an unbounded catch-up debt. Under prolonged acquisition stalls, simulation slows rather than applying one giant displacement. ClientPort initial streaming is still synchronous and may delay intent forwarding; issue #4 tracks that performance boundary. This slice provides the collision/authority prerequisites for new traversal; posture dimensions and reliable one-block jump acceptance remain separately tracked.