defmodule WyramGame.Characters do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :character
  alias WyramGame.{Models, Profiles}

  defcharacter Player, id: "player" do
    %{model: Models.Player, profile: Profiles.Player}
  end

  defcharacter Companion, id: "companion" do
    %{model: Models.Companion, profile: Profiles.Companion}
  end
end
