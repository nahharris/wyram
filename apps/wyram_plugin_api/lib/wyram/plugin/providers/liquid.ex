defmodule Wyram.Plugin.Providers.Liquid do
  @moduledoc "Validates and lowers bounded liquid flow settings."
  @behaviour Wyram.Plugin.Provider
  alias Wyram.Capability.Liquid
  alias Wyram.Plugin.{Descriptor, Diagnostic, SourceLocation}

  @impl true
  def config_module, do: Liquid
  @impl true
  def kinds, do: [:block]
  @impl true
  def config_schema, do: %{flow_ms: {:integer, 100..5000}, max_level: {:integer, 1..7}}
  @impl true
  def owned_fields, do: %{liquid: :exclusive}

  @impl true
  def validate(%Liquid{} = config, context) do
    fields = Map.from_struct(config)
    if Descriptor.valid_field?(:liquid, fields), do: :ok, else: invalid(context)
  end

  def validate(_, context), do: invalid(context)

  @impl true
  def lower(config, context) do
    with :ok <- validate(config, context), do: {:ok, %{liquid: Map.from_struct(config)}}
  end

  defp invalid(context) do
    source =
      case context do
        %{source: %SourceLocation{} = source} ->
          if SourceLocation.valid?(source), do: source, else: fallback_source()

        _ ->
          fallback_source()
      end

    {:error,
     [
       Diagnostic.new!(
         :invalid_liquid,
         "liquid requires flow_ms in 100..5000 and max_level in 1..7",
         source
       )
     ]}
  end

  defp fallback_source, do: %SourceLocation{file: "<plugin>", line: 1}
end
