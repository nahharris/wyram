defmodule CrossPluginBase.TintConfig do
  defstruct [:channel, :marker]
end

defmodule CrossPluginBase.ProviderHelper do
  @behaviour Wyram.Plugin.Provider

  @impl true
  def config_module, do: CrossPluginBase.TintConfig

  @impl true
  def kinds, do: [:block]

  @impl true
  def config_schema, do: %{channel: :atom, marker: :atom}

  @impl true
  def owned_fields, do: %{material: :exclusive}

  @impl true
  def validate(%CrossPluginBase.TintConfig{channel: :base}, _context), do: :ok

  def validate(_config, context) do
    {:error,
     [
       Wyram.Plugin.Diagnostic.new!(
         :invalid_tint_channel,
         "fixture tint channel must be :base",
         context.source
       )
     ]}
  end

  @impl true
  def lower(_config, _context),
    do: {:ok, %{material: %{color: implementation_rgb(), mode: :opaque}}}

  defp implementation_rgb, do: {20, 30, 40}
end
