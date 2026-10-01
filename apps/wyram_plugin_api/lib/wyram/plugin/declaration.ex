defmodule Wyram.Plugin.Declaration do
  @moduledoc "Typed, source-aware intermediate representation for a plugin declaration."

  alias Wyram.Block.Ref
  alias Wyram.Plugin.{CapabilityContribution, Diagnostic, SourceLocation}

  @enforce_keys [:plugin_id, :module, :kind, :role, :source]
  defstruct [:plugin_id, :local_id, :module, :kind, :role, :source, entries: []]

  @type role :: :registered | :template
  @type entry :: Template.t() | CapabilityContribution.t()
  @type t :: %__MODULE__{
          plugin_id: String.t(),
          local_id: String.t() | nil,
          module: module(),
          kind: :block,
          role: role(),
          source: SourceLocation.t(),
          entries: [entry()]
        }

  defmodule Template do
    @moduledoc "A source-ordered reference to a declaration used as a template."
    @enforce_keys [:module, :source]
    defstruct [:module, :source]

    @type t :: %__MODULE__{module: module(), source: Wyram.Plugin.SourceLocation.t()}

    @spec new!(module(), Wyram.Plugin.SourceLocation.t()) :: t()
    def new!(module, %Wyram.Plugin.SourceLocation{} = source) when is_atom(module),
      do: %__MODULE__{module: module, source: source}
  end

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t() | {atom(), String.t()}}
  def new(attrs) when is_map(attrs) do
    plugin_id = Map.get(attrs, :plugin_id)
    local_id = Map.get(attrs, :local_id)
    kind = Map.get(attrs, :kind)
    role = Map.get(attrs, :role)
    source = Map.get(attrs, :source)

    cond do
      not Ref.valid_plugin_id?(plugin_id) ->
        error(:invalid_plugin_id, "invalid plugin ID", source)

      not is_atom(Map.get(attrs, :module)) ->
        error(:invalid_declaration_module, "declaration module must be a module", source)

      kind != :block ->
        error(:invalid_declaration_kind, "unsupported declaration kind #{inspect(kind)}", source)

      role not in [:registered, :template] ->
        error(:invalid_declaration_role, "unsupported declaration role #{inspect(role)}", source)

      role == :registered and not Ref.valid_local_id?(local_id) ->
        error(:invalid_local_id, "registered blocks require a valid local ID", source)

      role == :template and not (is_nil(local_id) or Ref.valid_local_id?(local_id)) ->
        error(:invalid_local_id, "template local ID must be nil or valid", source)

      not match?(%SourceLocation{}, source) ->
        error(:invalid_source_location, "declaration needs a source location", nil)

      not valid_entries?(Map.get(attrs, :entries, [])) ->
        error(
          :invalid_declaration_entry,
          "entries must be ordered templates or capability contributions",
          source
        )

      true ->
        {:ok,
         %__MODULE__{
           plugin_id: plugin_id,
           local_id: local_id,
           module: Map.fetch!(attrs, :module),
           kind: kind,
           role: role,
           source: source,
           entries: Map.get(attrs, :entries, [])
         }}
    end
  end

  def new(_attrs), do: error(:invalid_declaration, "declaration must be a map", nil)

  defp valid_entries?(entries) when is_list(entries),
    do: Enum.all?(entries, &(match?(%Template{}, &1) or match?(%CapabilityContribution{}, &1)))

  defp valid_entries?(_), do: false

  defp error(code, message, %SourceLocation{} = source),
    do: {:error, Diagnostic.new!(code, message, source)}

  defp error(code, message, _), do: {:error, {code, message}}
end
