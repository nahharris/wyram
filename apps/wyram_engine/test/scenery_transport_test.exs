defmodule Wyram.Engine.Scenery.TransportTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.Scenery.Transport
  alias Wyram.Scenery.{Config, Key}

  test "only the matching credited delivery releases service work and new plans retire old credits" do
    {:ok, key} = Key.new({-1, 0, 2}, 1)
    plan = %{roots: [key], order: [key], nodes: %{key => []}, content: 7}
    tile = <<"WSL1", 1, 0, 0, 0, -1::little-signed-32, 0::little-signed-32, 2::little-signed-32>>
    link = %Transport{}
    assert {active, wire} = Transport.plan(link, 3, 0, plan, Config.new!(%{}))
    assert <<"WSP1", 3::64, _::binary>> = IO.iodata_to_binary(wire)
    token = make_ref()
    assert {waiting, bytes} = Transport.offer(active, 3, token, [{key, tile}])
    assert <<"WST1", 3::64, delivery::64, _::binary>> = IO.iodata_to_binary(bytes)
    assert waiting.waiting == {delivery, token}
    assert Transport.offer(waiting, 3, make_ref(), [{key, tile}]) == {waiting, nil}
    assert Transport.credit(waiting, 2, delivery) == {waiting, nil}
    assert Transport.credit(waiting, 3, delivery + 1) == {waiting, nil}
    assert {released, {3, ^token}} = Transport.credit(waiting, 3, delivery)
    assert released.waiting == nil
    assert {next, _} = Transport.plan(waiting, 4, 0, plan, Config.new!(%{}))
    assert next.waiting == nil
    assert Transport.credit(next, 3, delivery) == {next, nil}
    assert Transport.offer(next, 3, token, [{key, tile}]) == {next, nil}
    assert Transport.plan(next, 3, 0, plan, Config.new!(%{})) == {next, nil}
  end
end
