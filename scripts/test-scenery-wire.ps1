$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ('.tools\scenery-wire-test\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$source = Join-Path $directory 'fixture.exs'
$fixture = Join-Path $directory 'packets.bin'
@'
alias Wyram.Block.Ref
alias Wyram.Engine.WorldGenerator
alias Wyram.Engine.Scenery.{EditView, Fetch, Wire}
alias Wyram.Scenery.{Config, Key}
alias Wyram.WorldGen.Biome
import Bitwise
stone = Ref.new!("fixture", "stone")
generation_config = Wyram.WorldGen.Config.new!(%{
  biomes: [Biome.new!(%{id: "wilds", surface: stone, soil: stone, rock: stone})],
  carvers: [], islands: nil
})
{:ok, generation} = WorldGenerator.compile(generation_config, 41, [], %{"fixture:stone" => 42})
{:ok, parent} = Key.new({-1,-3,-1}, 2)
children = for octant <- 0..7 do
  {:ok, child} = Key.new({-2 + band(octant,1), -6 + band(octant >>> 1,1), -2 + (octant >>> 2)}, 1)
  child
end
order = [parent | children]
plan = %{roots: [parent], order: order, nodes: Map.put(Map.new(children,&{&1,[]}),parent,children), content: 7}
model = %{generation: generation, edits: EditView.new(%{{-4,-12,-4} => %{data: :binary.copy(<<0>>,8192)}}), stamp: 0}
frame = fn bytes -> [<<IO.iodata_length(bytes)::32>>,bytes] end
config = Config.new!(%{})
batches = order |> Enum.chunk_every(2) |> Enum.with_index(1) |> Enum.map(fn {keys,delivery} ->
  {:ok, tiles} = Fetch.run(model,keys)
  frame.(Wire.tiles(3,delivery,Enum.zip(keys,tiles)))
end)
coarse = %{plan | order: [parent], nodes: %{parent => []}}
packets = [frame.(Wire.plan(3,0,plan,config)),batches,
  frame.(Wire.plan(4,0,coarse,config)),frame.(Wire.plan(5,0,%{coarse | content: 8},config))]
File.write!(System.fetch_env!("WYRAM_SCENERY_FIXTURE"),packets)
'@ | Set-Content -LiteralPath $source -Encoding ASCII
$previous = $env:WYRAM_SCENERY_FIXTURE
try {
    $env:WYRAM_SCENERY_FIXTURE = $fixture
    mix run --no-start $source
    if ($LASTEXITCODE -ne 0) { throw 'Scenery server fixture failed' }
    cargo test --manifest-path native/Cargo.toml -p wyram_client --locked matched_server_wire_fixture -- --ignored
    if ($LASTEXITCODE -ne 0) { throw 'Scenery client fixture validation failed' }
} finally {
    if ($null -eq $previous) { Remove-Item Env:\WYRAM_SCENERY_FIXTURE -ErrorAction SilentlyContinue }
    else { $env:WYRAM_SCENERY_FIXTURE = $previous }
}
Write-Host 'Edited scenery transport and native cache identity smoke passed'
