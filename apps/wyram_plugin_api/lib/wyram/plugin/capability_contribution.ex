defmodule Wyram.Plugin.CapabilityContribution do
  @moduledoc "One ordered provider configuration within a declaration."

  alias Wyram.Plugin.SourceLocation

  @enforce_keys [:provider, :config, :source]
  defstruct [:provider, :config, :source, override: false, origin: :authored]

  @type t :: %__MODULE__{
          provider: module(),
          config: struct() | map(),
          source: SourceLocation.t(),
          override: boolean(),
          origin: :authored | :template | :default
        }

  @spec new!(module(), struct() | map(), SourceLocation.t(), keyword()) :: t()
  def new!(provider, config, %SourceLocation{} = source, opts \\ [])
      when is_atom(provider) and is_map(config) do
    contribution =
      struct!(
        __MODULE__,
        Keyword.merge([provider: provider, config: config, source: source], opts)
      )

    unless is_boolean(contribution.override),
      do: raise(ArgumentError, "capability override must be a boolean")

    unless contribution.origin in [:authored, :template, :default],
      do: raise(ArgumentError, "capability origin must be :authored, :template or :default")

    contribution
  end
end
