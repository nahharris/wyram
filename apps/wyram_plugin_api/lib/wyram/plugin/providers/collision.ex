defmodule Wyram.Plugin.Providers.Collision do
  @moduledoc "Validates and lowers supported block collision geometry."
  @behaviour Wyram.Plugin.Provider

  alias Wyram.Capability.Collision
  alias Wyram.Plugin.{Diagnostic, SourceLocation}
  alias Wyram.Shape.Cube

  @impl true
  def config_module, do: Collision

  @impl true
  def kinds, do: [:block]

  @impl true
  def config_schema, do: %{shape: Cube}

  @impl true
  def owned_fields, do: %{collision: :exclusive}

  @impl true
  def validate(%Collision{shape: shape} = config, context) do
    if valid_cube?(shape),
      do: validate_fields(config, context),
      else: invalid(config, context, "collision shape must be Wyram.Shape.Cube")
  end

  def validate(config, context),
    do: invalid(config, context, "collision config must be Wyram.Capability.Collision")

  @impl true
  def lower(%Collision{} = config, context) do
    with :ok <- validate(config, context) do
      {:ok, %{collision: %{primitive: :cube}}}
    end
  end

  def lower(config, context),
    do: invalid(config, context, "collision config must be Wyram.Capability.Collision")

  defp validate_fields(config, context) do
    case unknown_fields(config) do
      [] ->
        :ok

      fields ->
        {:error,
         [
           diagnostic(
             :unknown_config_field,
             "unknown collision fields: #{inspect(fields)}",
             context[:source]
           )
         ]}
    end
  end

  defp invalid(config, context, message) do
    case unknown_fields(config) do
      [] ->
        {:error, [diagnostic(:invalid_collision, message, context[:source])]}

      fields ->
        {:error,
         [
           diagnostic(
             :unknown_config_field,
             "unknown collision fields: #{inspect(fields)}",
             context[:source]
           )
         ]}
    end
  end

  defp unknown_fields(%{__struct__: Collision} = config),
    do: Map.keys(config) -- [:__struct__, :shape]

  defp unknown_fields(config) when is_map(config), do: Map.keys(config) -- [:shape]
  defp unknown_fields(_config), do: []

  defp valid_cube?(%Cube{} = cube), do: Map.keys(cube) == [:__struct__]
  defp valid_cube?(_), do: false

  defp diagnostic(code, message, %SourceLocation{} = source),
    do:
      Diagnostic.new!(
        code,
        message,
        if(SourceLocation.valid?(source), do: source, else: fallback_source())
      )

  defp diagnostic(code, message, _source), do: Diagnostic.new!(code, message, fallback_source())

  defp fallback_source, do: %Wyram.Plugin.SourceLocation{file: "<plugin>", line: 1}
end
