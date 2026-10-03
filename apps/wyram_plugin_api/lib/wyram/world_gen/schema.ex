defmodule Wyram.WorldGen.Schema do
  @moduledoc false
  alias Wyram.Block.Ref

  def new!(module, attrs) when is_map(attrs) do
    fields = Map.keys(module.__struct__()) -- [:__struct__]

    if Enum.any?(Map.keys(attrs), &(&1 not in fields)),
      do: raise(ArgumentError, "unknown world generation field")

    value = struct!(module, attrs)
    if module.validate(value) != :ok, do: raise(ArgumentError, "invalid #{inspect(module)}")
    value
  end

  def complete?(value, module) when is_map(value),
    do:
      Map.get(value, :__struct__) == module and
        Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(module.__struct__()))

  def complete?(_, _), do: false
  def number?(value, low, high), do: is_number(value) and value >= low and value <= high
  def integer?(value, low, high), do: is_integer(value) and value >= low and value <= high

  def ref?(%Ref{} = ref),
    do: complete?(ref, Ref) and match?({:ok, _}, Ref.new(ref.plugin_id, ref.local_id))

  def ref?(_), do: false
  def result(true), do: :ok
  def result(_), do: {:error, :invalid_worldgen}
end
