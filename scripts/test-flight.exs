alias Wyram.Character.{Input, State, Step}
alias Wyram.Engine.{Characters, Collision, Native, PluginManager, World}

profile = PluginManager.player_profile()
true = profile.fly_enabled
companion = Enum.find(PluginManager.character_definitions(), &(&1.id == "companion"))
false = companion.profile.fly_enabled
player = Characters.snapshot()
[x, _, z] = player.feet
context = World.generation()

{:ok, heights} =
  Native.surface_heights(context.resource, [
    {floor(x - profile.radius), floor(z - profile.radius)},
    {floor(x + profile.radius), floor(z - profile.radius)},
    {floor(x - profile.radius), floor(z + profile.radius)},
    {floor(x + profile.radius), floor(z + profile.radius)}
  ])

floor_y = Enum.max(heights) * 1.0
body = State.new(profile, {x, floor_y + 4.0, z})
request = %{Input.idle() | flight_request: 1}

step = fn body, input ->
  {:ok, %{"player" => next}} = Step.advance([{"player", body, input}], &Collision.sweep/1)
  false = next.unavailable
  next
end

hovering = step.(body, request)
true = hovering.mode == :fly
true = hovering.position == body.position
rising = Enum.reduce(1..20, hovering, fn _, b -> step.(b, %{request | jump: true}) end)
true = elem(rising.position, 1) > elem(hovering.position, 1) + 2.0

landed =
  Enum.reduce_while(1..150, rising, fn _, b ->
    next = step.(b, %{request | sneaking: true})
    if next.mode == :walk, do: {:halt, next}, else: {:cont, next}
  end)

true = landed.mode == :walk
true = landed.grounded
true = abs(elem(landed.position, 1) - floor_y) < 0.001
true = step.(landed, request).mode == :walk
true = step.(landed, %{request | flight_request: 2}).mode == :fly
IO.puts("Packaged player flight, packed collision landing and consumed gesture smoke passed")
