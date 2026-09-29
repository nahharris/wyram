# Local automation

Run `mise run setup` once, then `mise run dev:agent` to start the game with an opt-in control socket. The engine binds only to `127.0.0.1`, chooses a free port, and writes `control.json` under the game data directory (`%LOCALAPPDATA%\Wyram` or `WYRAM_DATA_DIR`). The file contains the port and a per-run token. Keep that file local. The normal `mise run dev` does not open the socket.

Send one JSON command per connection using `scripts/control.ps1`. It adds the token and prints one JSON response. Examples from a second PowerShell terminal:

```powershell
mise run control
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/control.ps1 -Json '{"op":"inspect","radius":2}'
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/control.ps1 -Json '{"op":"teleport","x":32.5,"y":75,"z":-7.5,"yaw":1.0,"pitch":0.0}'
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/control.ps1 -Json '{"op":"set_block","x":32,"y":74,"z":-8,"block":"wyram:wood"}'
```

For larger commands, write a JSON object to a file and pass `-RequestFile path.json`. Scripts in other languages can read `control.json`, connect to its loopback port, send a UTF-8 JSON line containing the token, and read one JSON response line. The token is required for every command.

`status` returns the latest reported player pose, plugin/block registry, region count, and BEAM process/memory counts. The client reports its pose about five times a second, so position is a recent observation. `inspect` returns non-air blocks, coordinates, IDs, names, and an air count in a cube centered on the player's block; radius defaults to 1 and is limited to 3. In headless mode, supply `"at":[x,y,z]` explicitly. `teleport` queues a client command and returns `accepted`; poll `status` to observe the new pose. `set_block` goes through the engine's normal validation and durable edit path. Coordinates for block operations are signed 32-bit integers. The control socket is intended for local trusted scripts, not remote clients.
