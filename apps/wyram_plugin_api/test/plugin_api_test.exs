defmodule Wyram.PluginApiTest do
  use ExUnit.Case, async: true

  test "API version is explicit" do
    assert Wyram.PluginApi.version() == 1
  end
end
