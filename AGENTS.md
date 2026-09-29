# Wyram development rules

- Keep gameplay authority and plugin contracts in Elixir. Native code owns packed voxel operations and presentation.
- Do not put a process behind every block or entity. Region actors own dense chunk data.
- The official plugin must use only the public plugin API.
- Keep native calls and renderer messages batched. Never block the renderer on a GenServer call.
- Use `mise run check` and `mise run test` before publishing changes. Keep Windows CI green.
- Never commit downloaded tools, generated assets, saves, logs, or build outputs.
