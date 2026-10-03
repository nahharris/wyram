defmodule Wyram.Characters do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :character
  alias Wyram.{Models, Profiles}

  defcharacter Player do
    %{model: Models.Player, profile: Profiles.Player}
  end

  defcharacter Companion do
    %{model: Models.Companion, profile: Profiles.Companion}
  end
end
