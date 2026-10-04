defmodule Wyram.Engine.Scenery.Transport do
  @moduledoc "One credited native delivery for the active visual epoch."
  defstruct epoch: 0, waiting: nil
  alias Wyram.Engine.Scenery.Wire

  def plan(link, epoch, stamp, plan, config, protocol \\ 2)

  def plan(link, epoch, stamp, plan, config, protocol) when epoch > link.epoch,
    do: {%__MODULE__{epoch: epoch}, Wire.plan(epoch, stamp, plan, config, protocol)}

  def plan(link, _, _, _, _, _), do: {link, nil}

  def offer(%{epoch: epoch, waiting: nil} = link, epoch, token, tiles) do
    delivery = System.unique_integer([:positive, :monotonic])
    {%{link | waiting: {delivery, token}}, Wire.tiles(epoch, delivery, tiles)}
  end

  def offer(link, _, _, _), do: {link, nil}

  def credit(%{epoch: epoch, waiting: {delivery, token}} = link, epoch, delivery),
    do: {%{link | waiting: nil}, {epoch, token}}

  def credit(link, _, _), do: {link, nil}
end
