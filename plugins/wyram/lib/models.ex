defmodule Wyram.Models do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :model

  defmodel Player, build: {Wyram.Models.DwarfBuilder, :player}
  defmodel Companion, build: {Wyram.Models.DwarfBuilder, :companion}
end
