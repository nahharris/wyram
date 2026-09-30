# Gameplay and reusable characters

[Roadmap #9](https://github.com/nahharris/wyram/issues/9) tracks richer voxel movement and character presentation. Each slice ships from an isolated worktree through a PR to `main`, with `mise run check`, `mise run test` and Windows CI. Existing work in another checkout must stay separate.

## Feasibility and delivery order

Walking, Ctrl-running and Space-jumping already exist. Their tuning was hard-coded in the native client, whose original frame-step collision checks sampled body corners. The authority slice replaces that solver with fixed-step Elixir state and packed swept-AABB queries. The posture slice adds variable character bodies. Fluid semantics remain future work. Editable original rigs now render both the player and a second character through a shared pipeline. A continuous jump apex of 1.225 blocks does not establish that the existing collision solver reliably clears a one-block obstacle.

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
| Four-direction rolling | Implemented as a timed four-direction swept action | [#19](https://github.com/nahharris/wyram/issues/19) |
| Reusable body, rig and models | Implemented; original role-based rigs and a second character | [#20](https://github.com/nahharris/wyram/issues/20) |
| Reusable animations | Implemented; original procedural clips retarget by semantic roles | [#21](https://github.com/nahharris/wyram/issues/21) |
| Third-person and front-facing cameras | Implemented; bounded collision-aware external views | [#22](https://github.com/nahharris/wyram/issues/22) |

The requested second-person camera is implemented as a front-facing external view looking back at the character. Character facing still controls movement and the head-origin edit ray in every view.

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


### Four-direction rolling

Press Q with WASD to roll forward, backward, left or right relative to character facing. The dominant local axis resolves diagonals; ties and Q alone select forward. Default tuning covers 3 blocks over 0.35 seconds, with a 0.8-second cooldown measured from entry. Profiles can disable or tune the action. It uses the approved prone body and preserves its entry direction. A normal Q release allows completion; jumping, other traversal requests, focus/Escape release, teleport, walls, ledges, lost support and unavailable terrain interrupt it. Low tunnels retain prone posture when standing remains blocked.

Input edges and cooldown prevent held/repeated Q from restarting it. A sticky cancellation flag survives input coalescing until a new key press; stale engine input also cancels the action. Prediction stays within the approved target. The action snapshot exposes direction, phase, elapsed time and duration for future reusable animation. Rolling adds no combat or invulnerability semantics.

### Models and reusable rigs

The public `Wyram.Character.Model`, `Definition` and `Catalog` values describe bounded models and character rosters. Optional game callbacks `character_models/0` and `characters/0` use only the public API; older plugins receive a default cuboid and player definition. The shared owner simulates every definition with its own profile, body and model reference. Player intent affects only the player; the companion currently remains idle under gravity and collision.

`plugins/wyram/lib/wyram_mods/characters.ex` contains two original editable cuboid characters with different proportions and bone names. Semantic roles, rather than those names, define compatibility. Ordered parented bones carry local pivots and cuboids; named hand/head attachments reference existing bones. Catalogs allow at most 16 models and 16 characters, 32 bones and 64 cuboids per model. Both Elixir and Rust validate geometry, hierarchy and references. Plugin compilation exports the source values in the initial client batch; Rust imports them into a cached rig and evaluates posed vertices in one bounded character draw batch. The full test task exports the actual plugin catalog into ignored `.tools/character-models.json` and imports it with `wyram_client --validate-models`.

Collision remains feet-space authority with profile dimensions. Rig evaluation anchors geometry at the approved feet and fits its height to the approved posture; meshes cannot choose collision or gameplay displacement. First person hides the player's body and renders the companion. External views reveal the player body, and state-driven animation retargets poses to both characters.
### State-driven animation

Rust selects original procedural idle, walk, run, sneak, crawl, jump, fall, landing, climb, floor-slide, wall-slide and four-direction roll poses from accepted snapshots. Semantic roles retarget the same poses onto both original rigs. Quaternion blending softens state changes; epoch/model changes reset blending. Landing recovery is a short presentation-only pose. Unsupported modes or rigs without humanoid capability use a rest-pose fallback. Missing individual roles safely remain at rest.

Gait time follows authoritative sequence time with at most 40 ms extrapolation and freezes during stale snapshots. Rolls use approved elapsed time, duration and local direction. No animation translates a character root in gameplay; posed geometry remains anchored to approved feet and fitted to approved posture height. Swimming/diving clips await fluid gameplay. These are editable prototype animations, with visual polish still requiring playtesting.
### Cameras

Press F5 to cycle first person, third person behind the character and a front-facing view looking back at the character. Mouse look still changes character facing and pitch. In external views, the captured mouse wheel adjusts distance from 1 to 6 blocks (default 3). The camera follows the approved eye height as posture or profile changes. A small camera body probes a straight line against the cached packed voxel replica, stopping before walls or ceilings; at most 60 probes share one borrowed packed world. Unknown terrain or insufficient room falls back to first person and hides the player body. No renderer request waits on Elixir.

Movement remains relative to character facing. Both breaking and placement always cast from the character's head along character look, retaining the existing six-block reach; switching to an external view never moves that ray to the camera. In front view the character's forward direction points away from the camera. F5 ignores key repeats and does not change held gameplay intent. Mouse capture and Escape retain their existing behavior. This prototype uses immediate follow and collision retraction; camera smoothing and art polish can follow playtesting.