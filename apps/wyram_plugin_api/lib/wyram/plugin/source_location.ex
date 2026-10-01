defmodule Wyram.Plugin.SourceLocation do
  @moduledoc "Source position retained by plugin declarations and diagnostics."

  @enforce_keys [:file, :line]
  defstruct [:file, :line, :column, :module]

  @type t :: %__MODULE__{
          file: String.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          module: module() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_source_location}
  def new(attrs) when is_map(attrs) do
    source = %__MODULE__{
      file: Map.get(attrs, :file),
      line: Map.get(attrs, :line),
      column: Map.get(attrs, :column),
      module: Map.get(attrs, :module)
    }

    if Map.keys(attrs) -- [:file, :line, :column, :module] == [] and valid?(source),
      do: {:ok, source},
      else: {:error, :invalid_source_location}
  end

  def new(_attrs), do: {:error, :invalid_source_location}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{file: file, line: line, column: column, module: module}) do
    is_binary(file) and file != "" and is_integer(line) and line > 0 and
      (is_nil(column) or (is_integer(column) and column > 0)) and
      (is_nil(module) or Wyram.Plugin.ModuleName.valid?(module))
  end

  def valid?(_), do: false
end
