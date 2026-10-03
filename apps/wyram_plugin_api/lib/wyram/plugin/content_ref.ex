defmodule Wyram.Plugin.ContentRef do
  @moduledoc "A persistent, kind-tagged reference to non-block plugin content."
  @enforce_keys [:plugin_id, :local_id, :kind]
  defstruct [:plugin_id, :local_id, :kind]
  @type t :: %__MODULE__{plugin_id: String.t(), local_id: String.t(), kind: atom()}

  def canonical_id(%__MODULE__{} = ref), do: ref.plugin_id <> ":" <> ref.local_id
end
