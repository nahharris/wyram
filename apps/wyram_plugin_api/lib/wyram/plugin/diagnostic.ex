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
    validate_options!(opts, source)

    diagnostic =
      struct!(__MODULE__, Keyword.merge([code: code, message: message, source: source], opts))

    validate_metadata!(diagnostic)

    diagnostic
  end

  defp validate_options!(opts, source) do
    allowed = [:declaration_id, :path, :related]

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
             SourceLocation.valid?(source),
           do: raise(ArgumentError, "invalid diagnostic options or source location")
  end

  defp validate_metadata!(diagnostic) do
    unless valid_declaration_id?(diagnostic.declaration_id) and valid_path?(diagnostic.path) and
             valid_related?(diagnostic.related),
           do: raise(ArgumentError, "invalid diagnostic metadata")
  end

  defp valid_declaration_id?(declaration_id),
    do: is_nil(declaration_id) or is_binary(declaration_id)

  defp valid_path?(path) when is_list(path),
    do: Enum.all?(path, &(is_atom(&1) or is_binary(&1)))

  defp valid_path?(_path), do: false

  defp valid_related?(related) when is_list(related),
    do: Enum.all?(related, &SourceLocation.valid?/1)

  defp valid_related?(_related), do: false
end
