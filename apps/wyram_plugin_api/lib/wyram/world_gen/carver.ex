defmodule Wyram.WorldGen.Carver do
  @moduledoc "A bounded density carver, applied before surfaces and features. Kinds: caves or rift."
  alias Wyram.WorldGen.{Field, Schema}

  defstruct kind: :caves,
            field: %Field{scale: 48.0, octaves: 2, salt: 71},
            threshold: 0.68,
            min_y: -184,
            max_y: 176,
            surface_buffer: 8

  def new!(attrs), do: Schema.new!(__MODULE__, attrs)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and value.kind in [:caves, :rift] and
        Field.validate(value.field) == :ok and Schema.number?(value.threshold, 0.5, 0.95) and
        Schema.integer?(value.min_y, -4096, 4095) and
        Schema.integer?(value.max_y, value.min_y, 4095) and
        Schema.integer?(value.surface_buffer, 0, 32)
    )
  end
end
