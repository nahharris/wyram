defmodule Wyram.Plugin.Diagnostic do
  @moduledoc "A source-aware error produced while compiling plugin declarations."

  alias Wyram.Plugin.SourceLocation

  @enforce_keys [:code, :message, :source]
  defstruct [:code, :message, :source, declaration_id: nil, path: [], related: []]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          source: SourceLocation.t(),
          declaration_id: String.t() | nil,
          path: [String.t() | atom()],
          related: [SourceLocation.t()]
        }

  @spec new!(atom(), String.t(), SourceLocation.t(), keyword()) :: t()
  def new!(code, message, %SourceLocation{} = source, opts \\ [])
      when is_atom(code) and is_binary(message) do
    struct!(__MODULE__, Keyword.merge([code: code, message: message, source: source], opts))
  end
end
