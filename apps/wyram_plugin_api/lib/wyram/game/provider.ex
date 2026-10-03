defmodule Wyram.Game.Provider do
  @moduledoc """
  Public build contract for game setup.

  The plugin compiler invokes explicitly declared providers and validates their
  output. The engine consumes compiled configuration data instead of callbacks.
  """

  @callback build() :: Wyram.Game.Config.t()
end
