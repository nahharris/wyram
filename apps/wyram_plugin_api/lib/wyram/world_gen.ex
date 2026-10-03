defmodule Wyram.WorldGen do
  @moduledoc "Author named, validated biome data with defbiome. Game builders assemble biomes/0 into a generation config."

  defmacro __using__(_options) do
    Module.register_attribute(__CALLER__.module, :wyram_biome_modules, accumulate: true)

    quote do
      import Wyram.WorldGen, only: [defbiome: 2]
      @before_compile Wyram.WorldGen
    end
  end

  defmacro defbiome({:__aliases__, _, [name]}, do: body) do
    module = Module.concat(__CALLER__.module, name)

    if module in Module.get_attribute(__CALLER__.module, :wyram_biome_modules),
      do: raise(ArgumentError, "duplicate biome declaration: #{name}")

    Module.put_attribute(__CALLER__.module, :wyram_biome_modules, module)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        alias Wyram.WorldGen.Biome
        def biome, do: Biome.new!(unquote(body))
      end
    end
  end

  defmacro defbiome(_, _),
    do: raise(ArgumentError, "defbiome requires a single module name and a data body")

  defmacro __before_compile__(env) do
    modules = env.module |> Module.get_attribute(:wyram_biome_modules) |> Enum.reverse()

    quote do
      def biomes, do: Enum.map(unquote(modules), & &1.biome())
    end
  end
end
