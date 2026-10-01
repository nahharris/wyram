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
end
