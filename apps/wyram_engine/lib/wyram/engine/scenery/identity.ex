defmodule Wyram.Engine.Scenery.Identity do
  @moduledoc "Stable visual identity independent of owners and development build profiles."
  alias Wyram.Engine.Native

  def new(generation, blocks) do
    {
      :scenery_cache_v1,
      Native.scenery_cache_version(),
      generation.identity,
      generation.seed,
      generation.bounds,
      Enum.sort(blocks)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  def tile(identity, key, samples) when is_binary(identity) and byte_size(identity) == 32 do
    {identity, key.position, key.level, :crypto.hash(:sha256, samples)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end
end
