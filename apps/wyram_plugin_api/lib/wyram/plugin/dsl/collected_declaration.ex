defmodule Wyram.Plugin.DSL.CollectedDeclaration do
  @moduledoc false
  @enforce_keys [:plugin, :module, :kind, :role, :source]
  defstruct [:plugin, :plugin_id, :local_id, :module, :kind, :role, :source, entries: []]
end

defmodule Wyram.Plugin.DSL.StructLiteral do
  @moduledoc false
  @enforce_keys [:module, :fields]
  defstruct [:module, :fields]
end

defmodule Wyram.Plugin.DSL.Capability do
  @moduledoc false
  @enforce_keys [:config_module, :config, :override, :source]
  defstruct [:config_module, :config, :override, :source]
end
