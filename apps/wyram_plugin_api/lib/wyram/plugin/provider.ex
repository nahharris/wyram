defmodule Wyram.Plugin.Provider do
  @moduledoc "Public contract implemented by capability providers."

  alias Wyram.Plugin.Diagnostic

  @type context :: %{
          optional(:source) => Wyram.Plugin.SourceLocation.t(),
          optional(atom()) => term()
        }
  @type descriptor_fields :: %{optional(atom()) => :exclusive}

  @callback config_module() :: module()
  @callback kinds() :: [atom()]
  @callback config_schema() :: map()
  @callback owned_fields() :: descriptor_fields()
  @callback validate(struct() | map(), context()) :: :ok | {:error, [Diagnostic.t()]}
  @callback lower(struct() | map(), context()) :: {:ok, map()} | {:error, [Diagnostic.t()]}

  @spec builtins() :: [module()]
  def builtins do
    [
      Wyram.Plugin.Providers.Geometry,
      Wyram.Plugin.Providers.Collision,
      Wyram.Plugin.Providers.Material
    ]
  end

  @spec for_config(module(), [module()]) ::
          {:ok, module()} | {:error, :unknown_provider | :ambiguous_provider}
  def for_config(config_module, providers) when is_atom(config_module) and is_list(providers) do
    if Wyram.Plugin.ModuleName.valid?(config_module) do
      matches =
        Enum.filter(providers, fn provider ->
          valid_provider?(provider) and safe_config_module(provider) == config_module
        end)

      case matches do
        [provider] -> {:ok, provider}
        [] -> {:error, :unknown_provider}
        _ -> {:error, :ambiguous_provider}
      end
    else
      {:error, :unknown_provider}
    end
  end

  def for_config(_config_module, _providers), do: {:error, :unknown_provider}

  @spec ownership_conflicts([module()]) :: [%{field: atom(), providers: [module()]}]
  def ownership_conflicts(providers) do
    providers
    |> Enum.reduce(%{}, fn provider, owners ->
      Enum.reduce(provider.owned_fields(), owners, fn {field, :exclusive}, acc ->
        Map.update(acc, field, [provider], &(&1 ++ [provider]))
      end)
    end)
    |> Enum.filter(fn {_field, owners} -> length(owners) > 1 end)
    |> Enum.map(fn {field, owners} -> %{field: field, providers: owners} end)
    |> Enum.sort_by(& &1.field)
  end

  defp valid_provider?(provider) do
    Wyram.Plugin.ModuleName.valid?(provider) and Code.ensure_loaded?(provider) and
      Enum.all?(
        [config_module: 0, kinds: 0, config_schema: 0, owned_fields: 0, validate: 2, lower: 2],
        fn {name, arity} ->
          function_exported?(provider, name, arity)
        end
      ) and valid_metadata?(provider)
  rescue
    _ -> false
  end

  defp valid_metadata?(provider) do
    config_module = provider.config_module()
    kinds = provider.kinds()
    schema = provider.config_schema()
    fields = provider.owned_fields()

    Wyram.Plugin.ModuleName.valid?(config_module) and Code.ensure_loaded?(config_module) and
      function_exported?(config_module, :__struct__, 0) and is_list(kinds) and kinds != [] and
      Enum.all?(kinds, &(&1 == :block)) and length(Enum.uniq(kinds)) == length(kinds) and
      valid_schema?(schema, config_module) and is_map(fields) and
      Enum.all?(fields, fn {field, ownership} ->
        is_atom(field) and field not in [nil, false, true] and ownership == :exclusive
      end)
  rescue
    _ -> false
  end

  defp valid_schema?(schema, config_module) when is_map(schema) do
    allowed = config_module.__struct__() |> Map.keys() |> List.delete(:__struct__)
    Enum.sort(Map.keys(schema)) == Enum.sort(allowed)
  end

  defp valid_schema?(_, _), do: false

  defp safe_config_module(provider) do
    provider.config_module()
  rescue
    _ -> nil
  end
end
