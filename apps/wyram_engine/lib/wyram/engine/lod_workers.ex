defmodule Wyram.Engine.LodWorkers do
  @moduledoc "Pure worker-budget resolution for progressive LOD generation and meshing."

  @max_workers 8
  @generation_env "WYRAM_LOD_GEN_WORKERS"
  @meshing_env "WYRAM_LOD_MESH_WORKERS"

  @spec overrides((String.t() -> String.t() | nil)) :: %{
          generation: nil | 1..8,
          meshing: nil | 1..8
        }
  def overrides(env_getter \\ &System.get_env/1) when is_function(env_getter, 1) do
    %{
      generation: parse_override(env_getter.(@generation_env), @generation_env),
      meshing: parse_override(env_getter.(@meshing_env), @meshing_env)
    }
  end

  @spec resolve(term(), term(), map()) :: %{
          parallelism: pos_integer(),
          budget: 2..8,
          generation: 1..8,
          meshing: 1..8
        }
  def resolve(client_parallelism, dirty_online, overrides \\ overrides()) do
    parallelism =
      if positive_integer?(client_parallelism) and positive_integer?(dirty_online),
        do: min(client_parallelism, dirty_online),
        else: 4

    budget = min(@max_workers, max(2, div(parallelism, 2) - 2))
    generation = div(budget + 1, 2)
    meshing = div(budget, 2)

    %{
      parallelism: parallelism,
      budget: budget,
      generation: override(overrides, :generation, generation, @generation_env),
      meshing: override(overrides, :meshing, meshing, @meshing_env)
    }
  end

  defp parse_override(nil, _name), do: nil

  defp parse_override(value, name) when is_binary(value) do
    case Integer.parse(value) do
      {workers, ""} when workers in 1..@max_workers ->
        workers

      _ ->
        raise ArgumentError, "#{name} must be a whole integer from 1 to #{@max_workers}"
    end
  end

  defp parse_override(_value, name),
    do: raise(ArgumentError, "#{name} must be a whole integer from 1 to #{@max_workers}")

  defp override(overrides, key, default, env_name) when is_map(overrides) do
    case Map.get(overrides, key) do
      nil ->
        default

      value when is_integer(value) and value in 1..@max_workers ->
        value

      _ ->
        raise ArgumentError, "#{env_name} override must be an integer from 1 to #{@max_workers}"
    end
  end

  defp override(_overrides, _key, _default, env_name),
    do: raise(ArgumentError, "#{env_name} override must be an integer from 1 to #{@max_workers}")

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
