defmodule Wyram.Plugin.Providers.Material do
  @moduledoc "Validates and lowers supported block material settings."
  @behaviour Wyram.Plugin.Provider

  alias Wyram.Capability.Material
  alias Wyram.Plugin.{Diagnostic, SourceLocation}

  @modes [:opaque]

  @impl true
  def config_module, do: Material

  @impl true
  def kinds, do: [:block]

  @impl true
  def config_schema, do: %{color: :rgb8, mode: :opaque}

  @impl true
  def owned_fields, do: %{material: :exclusive}

  @impl true
  def validate(%Material{color: color, mode: mode} = config, context) do
    cond do
      unknown_fields(config) != [] ->
        invalid(
          :unknown_config_field,
          "unknown material fields: #{inspect(unknown_fields(config))}",
          context
        )

      not valid_rgb?(color) ->
        invalid(
          :invalid_material_color,
          "material color must be an RGB tuple of integers from 0 to 255",
          context
        )

      mode not in @modes ->
        invalid(
          :unsupported_material_mode,
          "only opaque material is supported by this backend",
          context
        )

      true ->
        :ok
    end
  end

  def validate(config, context),
    do:
      invalid(
        :invalid_material,
        "material config must be Wyram.Capability.Material",
        context,
        inspect(config)
      )

  @impl true
  def lower(%Material{color: color, mode: mode} = config, context) do
    with :ok <- validate(config, context) do
      {:ok, %{material: %{color: color, mode: mode}}}
    end
  end

  def lower(config, context), do: validate(config, context)

  defp unknown_fields(config) do
    if is_map(config) do
      allowed =
        if Map.get(config, :__struct__) == Material,
          do: [:__struct__, :color, :mode],
          else: [:color, :mode]

      Map.keys(config) -- allowed
    else
      []
    end
  end

  defp valid_rgb?({r, g, b}),
    do: Enum.all?([r, g, b], &(is_integer(&1) and &1 >= 0 and &1 <= 255))

  defp valid_rgb?(_), do: false

  defp invalid(code, message, context, detail \\ nil) do
    message = if detail, do: message <> ": " <> detail, else: message
    {:error, [Diagnostic.new!(code, message, source(context))]}
  end

  defp source(%{source: %SourceLocation{} = source}) do
    if SourceLocation.valid?(source), do: source, else: source(%{})
  end

  defp source(_context), do: %Wyram.Plugin.SourceLocation{file: "<plugin>", line: 1}
end
