defmodule Wyram.Engine.BlockRegistry do
  @moduledoc "Finite liquid states share packed handles with blocks and persistent logical names."

  def expand(blocks) do
    Enum.flat_map(blocks, fn block ->
      case block.descriptor do
        %{liquid: %{max_level: max}} ->
          [
            Map.put(block, :state, {block.id, 0, false})
            | Enum.map(1..max, fn level ->
                block
                |> Map.put(:id, block.id <> "#flow_#{level}")
                |> Map.put(:state, {block.id, level, false})
              end)
          ] ++
            [
              block
              |> Map.put(:id, block.id <> "#falling")
              |> Map.put(:state, {block.id, max + 1, true})
            ]

        _ ->
          [block]
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  def tables(blocks, ids) do
    liquids =
      Map.new(Enum.filter(blocks, &Map.has_key?(&1, :state)), fn block ->
        {name, level, falling} = block.state
        config = block.descriptor.liquid

        variants =
          [ids[name] | Enum.map(1..config.max_level, &ids[name <> "#flow_#{&1}"])] ++
            [ids[name <> "#falling"]]

        {ids[block.id],
         Map.merge(config, %{
           source: ids[name],
           level: level,
           falling: falling,
           variants: variants,
           identity: name
         })}
      end)

    render =
      Map.new(blocks, fn block ->
        id = ids[block.id]
        material = block.descriptor.material
        liquid = liquids[id]

        height =
          if liquid && liquid.level > 0 && not liquid.falling,
            do: (liquid.max_level + 1 - liquid.level) / (liquid.max_level + 1),
            else: 1.0

        {id,
         %{
           opacity: Map.get(material, :opacity, 255),
           emissive: material.mode == :emissive,
           height: height,
           liquid: if(liquid, do: liquid.source, else: 0)
         }}
      end)

    noncolliding =
      blocks
      |> Enum.filter(&(&1.descriptor.collision.primitive == :none))
      |> Enum.map(&ids[&1.id])
      |> Enum.sort()

    %{liquids: liquids, render: render, noncolliding: noncolliding}
  end
end
