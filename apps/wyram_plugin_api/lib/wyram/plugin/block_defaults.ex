defmodule Wyram.Plugin.BlockDefaults do
  @moduledoc "Public default provider contributions for a solid opaque block."

  alias Wyram.Capability.{Collision, Geometry, Material}
  alias Wyram.Plugin.CapabilityContribution
  alias Wyram.Plugin.SourceLocation
  alias Wyram.Shape.Cube

  @spec entries(SourceLocation.t()) :: [CapabilityContribution.t()]
  def entries(%SourceLocation{} = source) do
    [
      CapabilityContribution.new!(
        Wyram.Plugin.Providers.Geometry,
        %Geometry{shape: %Cube{}},
        source,
        origin: :default
      ),
      CapabilityContribution.new!(
        Wyram.Plugin.Providers.Collision,
        %Collision{shape: %Cube{}},
        source,
        origin: :default
      ),
      CapabilityContribution.new!(
        Wyram.Plugin.Providers.Material,
        %Material{color: {255, 255, 255}, mode: :opaque},
        source,
        origin: :default
      )
    ]
  end
end
