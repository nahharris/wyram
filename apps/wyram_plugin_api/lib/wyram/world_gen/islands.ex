defmodule Wyram.WorldGen.Islands do
  @moduledoc "Disconnected floating landmasses with a coherent footprint, shaped underside and independent elevation."
  alias Wyram.WorldGen.{Field, Schema}

  defstruct field: %Field{scale: 384.0, octaves: 3, salt: 97},
            base_y: 224,
            thickness: 40,
            relief: 32,
            threshold: 0.62

  def new!(attrs), do: Schema.new!(__MODULE__, attrs)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and Field.validate(value.field) == :ok and
        Schema.integer?(value.base_y, -4096, 4095) and Schema.integer?(value.thickness, 4, 96) and
        Schema.integer?(value.relief, 0, 64) and Schema.number?(value.threshold, 0.5, 0.9)
    )
  end
end
