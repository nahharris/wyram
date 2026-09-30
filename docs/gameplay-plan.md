# Gameplay and reusable characters

[Roadmap #9](https://github.com/nahharris/wyram/issues/9) tracks richer voxel movement and character presentation. Each slice ships from an isolated worktree through a PR to `main`, with `mise run check`, `mise run test` and Windows CI. Existing work in another checkout must stay separate.

## Feasibility and delivery order

Walking, Ctrl-running and Space-jumping already exist. Their tuning was hard-coded in the native client, whose original frame-step collision checks sampled body corners. The authority slice replaces that solver with fixed-step Elixir state and packed swept-AABB queries. The posture slice adds variable character bodies. Fluid semantics, character models, skeletons, animation clips and external cameras remain future work. A continuous jump apex of 1.225 blocks does not establish that the existing collision solver reliably clears a one-block obstacle.

| Work | Readiness and dependency | Issue |
| --- | --- | --- |
| Public character profiles and Elixir walk/run policy | Implemented; preserves controls and tuning | [#10](https://github.com/nahharris/wyram/issues/10) |
| Fixed-step character authority and batched swept collision | Implemented foundation; explicit unknown-terrain handling | [#11](https://github.com/nahharris/wyram/issues/11) |
| Sneaking | Implemented; reduced height, slow movement, safe ledges | [#12](https://github.com/nahharris/wyram/issues/12) |
| Prone crawling | Implemented through shared posture clearance | [#13](https://github.com/nahharris/wyram/issues/13) |
| Guaranteed one-block jumping | Collision-backed clearance and landing verified across render schedules | [#14](https://github.com/nahharris/wyram/issues/14) |
| Climbing/mantling up to three blocks | Implemented through supported swept traversal phases | [#15](https://github.com/nahharris/wyram/issues/15) |
| Floor sliding | Implemented with crouched momentum and swept interruption | [#16](https://github.com/nahharris/wyram/issues/16) |
| Wall sliding | Implemented with fresh deliberate contact and a descent cap | [#17](https://github.com/nahharris/wyram/issues/17) |
| Swimming and diving | Deferred until public fluid semantics and water presentation exist | [#18](https://github.com/nahharris/wyram/issues/18) |
| Four-direction rolling | Requires swept action movement, clearance and interruption rules | [#19](https://github.com/nahharris/wyram/issues/19) |
| Reusable body, rig and models | Design alongside movement; demonstrate a second character | [#20](https://github.com/nahharris/wyram/issues/20) |
| Reusable animations | Requires rig and approved character state/phase snapshots | [#21](https://github.com/nahharris/wyram/issues/21) |
| Third-person and front-facing cameras | Requires visible model and body coordinates independent of the camera | [#22](https://github.com/nahharris/wyram/issues/22) |

The requested second-person camera is provisionally interpreted as a front-facing external view looking back at the character. Confirm that meaning before the camera implementation. The movement direction, targeting origin and edit reach must have explicit rules when switching views.

## Shared locomotion policy

`Wyram.Character.Profile` is a public immutable Elixir value loaded through the game's optional `player_profile/0` callback. Plugins without that callback retain default tuning. Validation rejects unsafe speeds and body geometry; each character uses its own profile.

The native client sends bounded key and look intent. Elixir chooses walk/run/sneak speed, posture, jump eligibility and displacement. Focus loss, Escape and teleports clear held input. Profile policy, collision dimensions and feet coordinates are independent of models and camera presentation.
## Reuse boundary

Elixir owns character capabilities, action eligibility, transitions and gameplay displacement. Region actors or a bounded simulation owner hold dense character state; no process per block or character. Native code supplies batched packed-voxel queries and performs prediction, rendering, rig evaluation, clip blending and cameras. Never make the renderer wait on a GenServer or native pipe write.

Use feet-space collision bodies independent of eye position, meshes and rigs. Character profiles specify capabilities/tuning; a future animation mapping consumes approved locomotion/posture/action phases. Root motion cannot silently become a second gameplay authority. Model import and rig conventions must work for a second character. Build outputs and downloaded tools remain ignored; original editable source assets need an explicit source/runtime pipeline.
## Authoritative character foundation

Issue #11 replaces client pose reports with bounded `input` packets carrying sequence and epoch. Elixir normalizes direction, selects profile speed, advances 20 ms steps, gates jumps on grounded input edges and applies gravity. Region actors return immutable chunk binaries grouped by owner; one dirty CPU NIF resolves each body-query batch. Query limits are 256 bodies, 4096 chunks, 4096 candidate cells per body, positions within one million blocks and displacements within eight blocks per axis. Missing terrain or failed acquisition explicitly freezes the body as unavailable. Current non-air blocks are solid; fluid semantics remain deferred.

Standing bodies use feet coordinates, radius 0.28, height 1.8 and eye offset 1.62. Eye coordinates remain in control snapshots for compatibility. The native client reconciles epoch/sequence-tagged state and predicts at most 40 ms of approved velocity against its visual replica. It does not choose speed, gravity, jump eligibility or position from raw keys. Input is coalesced in one reserved outbound slot; 100 ms heartbeats keep it live, and the engine expires movement after 250 ms without accepted input. Teleports check clearance, reset motion/input and use a new epoch. Owner restarts also publish a new epoch so old snapshots and inputs cannot displace the reset body.

The shared owner schedules one next tick and does not accumulate an unbounded catch-up debt. Under prolonged acquisition stalls, simulation slows rather than applying one giant displacement. ClientPort initial streaming is still synchronous and may delay intent forwarding; issue #4 tracks that performance boundary. This slice provides the collision/authority prerequisites for new traversal; reliable one-block jump acceptance remains separately tracked.
### Sneaking

Hold Left Shift to request crouching. Elixir selects profile-specific body height, eye height and sneak speed, which takes precedence over running. Shrinking keeps the feet anchored; expanding requires complete standing-body clearance. Releasing Shift under a ceiling retains crouching until standing fits. Grounded sneaking preserves support at cardinal and diagonal ledges; an intentional jump bypasses this protection. Collision, posture and support queries run in reusable batches for all characters. The default crouched height is one block, eye height 0.85 and speed 2 blocks/second.


### Crawling

Hold C to request prone crawling. Prone takes precedence over Shift and Ctrl; the default profile uses height 0.6, eye offset 0.45 and speed 1 block/second. Releasing C requests standing, but stays prone while the standing body is blocked. Shift can request a clearance-checked intermediate crouch. Feet never move as a side effect of posture changes. Crawling shares grounded ledge protection with sneaking, and solid voxel steps remain collision obstacles. Focus loss, Escape, teleport and stale input clear crawl intent; expansion remains subject to clearance.

### One-block jumping

Space uses a grounded input edge: release and press again after landing to jump again. Holding Space does not repeat or queue a landing jump. The initial policy has no coyote time and no input buffer. Default impulse 7 and gravity 20 clear and land on one-block obstacles at cardinal and diagonal approaches, but cannot clear two blocks. Swept ceiling hits cancel upward velocity. The public 20 ms timestep drives both integration and owner scheduling; render frequency does not select it. Collision-backed replays cover 30/60/144 Hz and skipped presentation frames. A stalled authority owner still slows simulation without accumulating catch-up debt.


### Ledge climbing

Hold E with a movement direction to deliberately climb a ledge up to three blocks. The dominant world direction resolves diagonal input; ties prefer the horizontal X axis. Elixir searches the lowest reachable height, checks a complete vertical rise, a horizontal crossing and supported destination before entry, then advances those phases at profile climb speed (default 4 blocks/second). The default maximum is three; profiles can disable climbing with maximum zero. Space remains the ordinary one-block jump.

Release E, request a lower posture, teleport, loss of landing support, blocked path or unavailable terrain cancels traversal. A held E does not re-enter until released. Each active step rechecks destination support and sweeps actual displacement; camera and future animation follow approved `action`, `phase` and position snapshots. No mesh or animation owns traversal displacement.


### Floor sliding

While running with Ctrl, press Shift to slide if grounded and already moving at least the profile entry speed (default 6 blocks/second). Slide preserves the entry direction, shrinks to the approved crouched body, and decelerates with friction (default 10 blocks/second squared) for at most 0.6 seconds. Slow entry falls back to ordinary sneaking. Profiles can disable sliding.

Releasing Ctrl/Shift, jumping, crawling, climbing, wall contact, lost support, or unavailable terrain ends the slide. Grounded ledge protection prevents sliding off an edge. On exit, standing still requires clearance; a low tunnel retains crouching. Holding the controls does not repeatedly restart the slide. Timers and displacement share authoritative fixed steps; presentation consumes the approved action independently.


### Wall sliding

While descending, hold Shift and push a movement direction into a wall to cap fall speed (default 2 blocks/second). Every fixed step probes current horizontal contact in a batch; prior contact cannot keep the character attached to a removed wall. Steering away, releasing Shift, requesting another action, lost contact, landing and unavailable terrain end the state. Ascending contact does not activate it. Space does not introduce a wall jump. Profiles can disable wall sliding or tune the descent cap, and presentation follows the approved action.
