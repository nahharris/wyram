defmodule Wyram.Block.Ref do
  @moduledoc "Logical block identity used in plugin code; registry handles are assigned later."

  @enforce_keys [:plugin_id, :local_id]
  defstruct [:plugin_id, :local_id]

  @type t :: %__MODULE__{plugin_id: String.t(), local_id: String.t()}

  @id_pattern ~r/^[a-z][a-z0-9_-]*$/

  @spec new(String.t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_plugin_id | :invalid_local_id}
  def new(plugin_id, local_id) do
    with :ok <- validate_plugin_id(plugin_id),
         :ok <- validate_local_id(local_id) do
      {:ok, %__MODULE__{plugin_id: plugin_id, local_id: local_id}}
    end
  end

  @spec new!(String.t(), String.t()) :: t()
  def new!(plugin_id, local_id) do
    case new(plugin_id, local_id) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid block reference: #{reason}"
    end
  end

  @spec valid_plugin_id?(term()) :: boolean()
  def valid_plugin_id?(id), do: valid_id?(id)

  @spec valid_local_id?(term()) :: boolean()
  def valid_local_id?(id), do: valid_id?(id)

  @spec canonical_id(t()) :: String.t()
  def canonical_id(%__MODULE__{plugin_id: plugin_id, local_id: local_id}),
    do: plugin_id <> ":" <> local_id

  defp validate_plugin_id(id), do: if(valid_id?(id), do: :ok, else: {:error, :invalid_plugin_id})
  defp validate_local_id(id), do: if(valid_id?(id), do: :ok, else: {:error, :invalid_local_id})
  defp valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  defp valid_id?(_), do: false
end
