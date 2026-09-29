defmodule Wyram.PluginApi do
  @moduledoc "The stable API version exposed to game plugins."
  @api_version 1

  @spec version() :: pos_integer()
  def version, do: @api_version
end
