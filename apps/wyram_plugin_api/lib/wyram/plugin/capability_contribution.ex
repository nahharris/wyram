defmodule Wyram.Plugin.CapabilityContribution do
  @moduledoc "One ordered provider configuration within a declaration."

  alias Wyram.Plugin.{ModuleName, SourceLocation}

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
      when is_map(config) do
    allowed = [:override, :origin]

    unless ModuleName.valid?(provider) and SourceLocation.valid?(source) and
             Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [],
           do: raise(ArgumentError, "invalid capability provider, source or options")

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

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{
        provider: provider,
        config: config,
        source: source,
        override: override,
        origin: origin
      }) do
    ModuleName.valid?(provider) and is_map(config) and SourceLocation.valid?(source) and
      is_boolean(override) and origin in [:authored, :template, :default]
  end

  def valid?(_), do: false
end
