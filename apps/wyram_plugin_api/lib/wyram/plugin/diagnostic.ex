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
    allowed = [:declaration_id, :path, :related]

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
             SourceLocation.valid?(source),
           do: raise(ArgumentError, "invalid diagnostic options or source location")

    diagnostic =
      struct!(__MODULE__, Keyword.merge([code: code, message: message, source: source], opts))

    unless (is_nil(diagnostic.declaration_id) or is_binary(diagnostic.declaration_id)) and
             is_list(diagnostic.path) and
             Enum.all?(diagnostic.path, &(is_atom(&1) or is_binary(&1))) and
             is_list(diagnostic.related) and
             Enum.all?(diagnostic.related, &SourceLocation.valid?/1),
           do: raise(ArgumentError, "invalid diagnostic metadata")

    diagnostic
  end
end
