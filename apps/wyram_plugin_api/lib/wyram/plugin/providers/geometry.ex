defmodule Wyram.Plugin.Providers.Geometry do
  @moduledoc "Validates and lowers supported block geometry."
  @behaviour Wyram.Plugin.Provider

  alias Wyram.Capability.Geometry
  alias Wyram.Plugin.Diagnostic
  alias Wyram.Shape.Cube

  @impl true
  def config_module, do: Geometry

  @impl true
  def kinds, do: [:block]

  @impl true
  def config_schema, do: %{shape: Cube}

  @impl true
  def owned_fields, do: %{geometry: :exclusive}

  @impl true
  def validate(%Geometry{shape: shape} = config, context) do
    if valid_cube?(shape),
      do: validate_fields(config, [:shape], context),
      else: invalid(config, context, "geometry shape must be Wyram.Shape.Cube")
  end

  def validate(config, context),
    do: invalid(config, context, "geometry config must be Wyram.Capability.Geometry")

  @impl true
  def lower(%Geometry{} = config, context) do
    with :ok <- validate(config, context) do
      {:ok, %{geometry: %{primitive: :cube}}}
    end
  end

  def lower(config, context),
    do: invalid(config, context, "geometry config must be Wyram.Capability.Geometry")

  defp validate_fields(config, allowed, context) do
    case unknown_fields(config, allowed) do
      [] ->
        :ok

      fields ->
        {:error,
         [
           diagnostic(
             :unknown_config_field,
             "unknown geometry fields: #{inspect(fields)}",
             context[:source]
           )
         ]}
    end
  end

  defp invalid(config, context, message) do
    case unknown_fields(config, [:shape]) do
      [] ->
        {:error, [diagnostic(:invalid_geometry, message, context[:source])]}

      fields ->
        {:error,
         [
           diagnostic(
             :unknown_config_field,
             "unknown geometry fields: #{inspect(fields)}",
             context[:source]
           )
         ]}
    end
  end

  defp unknown_fields(%{__struct__: Geometry} = config, allowed),
    do: Map.keys(config) -- [:__struct__ | allowed]

  defp unknown_fields(config, allowed) when is_map(config), do: Map.keys(config) -- allowed
  defp unknown_fields(_config, _allowed), do: []

  defp valid_cube?(%Cube{} = cube), do: Map.keys(cube) == [:__struct__]
  defp valid_cube?(_), do: false

  defp diagnostic(code, message, %Wyram.Plugin.SourceLocation{} = source),
    do:
      Diagnostic.new!(
        code,
        message,
        if(Wyram.Plugin.SourceLocation.valid?(source), do: source, else: fallback_source())
      )

  defp diagnostic(code, message, _source), do: Diagnostic.new!(code, message, fallback_source())

  defp fallback_source, do: %Wyram.Plugin.SourceLocation{file: "<plugin>", line: 1}
end
