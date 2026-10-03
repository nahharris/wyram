defmodule Wyram.WorldGen.Field do
  @moduledoc "A deterministic, world-space coherent noise field. Scale is in blocks; salt separates random streams."
  alias Wyram.WorldGen.Schema
  defstruct scale: 256.0, octaves: 3, salt: 0
  @type t :: %__MODULE__{scale: number(), octaves: integer(), salt: non_neg_integer()}
  def new!(attrs), do: Schema.new!(__MODULE__, attrs)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and Schema.number?(value.scale, 16, 8192) and
        Schema.integer?(value.octaves, 1, 5) and Schema.integer?(value.salt, 0, 4_294_967_295)
    )
  end
end
