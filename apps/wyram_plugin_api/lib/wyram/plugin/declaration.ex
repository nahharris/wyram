defmodule Wyram.Plugin.Declaration do
  @moduledoc "Typed, source-aware intermediate representation for a plugin declaration."

  alias Wyram.Block.Ref
  alias Wyram.Plugin.{CapabilityContribution, Diagnostic, ModuleName, SourceLocation}
  alias Wyram.Plugin.Declaration.Template

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
    def new!(module, %Wyram.Plugin.SourceLocation{} = source) do
      if ModuleName.valid?(module) and SourceLocation.valid?(source),
        do: %__MODULE__{module: module, source: source},
        else: raise(ArgumentError, "invalid template module or source")
    end

    @spec valid?(term()) :: boolean()
    def valid?(%__MODULE__{module: module, source: source}),
      do: ModuleName.valid?(module) and SourceLocation.valid?(source)

    def valid?(_), do: false
  end

  @spec new(map()) :: {:ok, t()} | {:error, Diagnostic.t() | {atom(), String.t()}}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_attrs(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: error(:invalid_declaration, "declaration must be a map", nil)

  defp validate_attrs(attrs) do
    with :ok <- validate_allowed_fields(attrs),
         :ok <- validate_identity(attrs),
         :ok <- validate_kind(attrs),
         :ok <- validate_role(attrs),
         :ok <- validate_source(attrs) do
      validate_entries(attrs)
    end
  end

  defp validate_allowed_fields(attrs) do
    allowed = [:plugin_id, :local_id, :module, :kind, :role, :source, :entries]
    unknown = Map.keys(attrs) -- allowed

    if unknown == [],
      do: :ok,
      else:
        error(
          :unknown_declaration_field,
          "unknown declaration fields: #{inspect(unknown)}",
          Map.get(attrs, :source)
        )
  end

  defp validate_identity(attrs) do
    source = Map.get(attrs, :source)

    cond do
      not Ref.valid_plugin_id?(Map.get(attrs, :plugin_id)) ->
        error(:invalid_plugin_id, "invalid plugin ID", source)

      not ModuleName.valid?(Map.get(attrs, :module)) ->
        error(:invalid_declaration_module, "declaration module must be a module", source)

      true ->
        :ok
    end
  end

  defp validate_kind(attrs) do
    case Map.get(attrs, :kind) do
      :block ->
        :ok

      kind ->
        error(
          :invalid_declaration_kind,
          "unsupported declaration kind #{inspect(kind)}",
          Map.get(attrs, :source)
        )
    end
  end

  defp validate_role(attrs) do
    source = Map.get(attrs, :source)
    local_id = Map.get(attrs, :local_id)

    case Map.get(attrs, :role) do
      :registered ->
        if Ref.valid_local_id?(local_id),
          do: :ok,
          else: error(:invalid_local_id, "registered blocks require a valid local ID", source)

      :template ->
        if is_nil(local_id),
          do: :ok,
          else:
            error(
              :invalid_local_id,
              "template declarations cannot have a persistent local ID",
              source
            )

      role ->
        error(:invalid_declaration_role, "unsupported declaration role #{inspect(role)}", source)
    end
  end

  defp validate_source(attrs) do
    case Map.get(attrs, :source) do
      %SourceLocation{} = source ->
        if SourceLocation.valid?(source),
          do: :ok,
          else: error(:invalid_source_location, "declaration needs a valid source location", nil)

      _ ->
        error(:invalid_source_location, "declaration needs a valid source location", nil)
    end
  end

  defp validate_entries(attrs) do
    if valid_entries?(Map.get(attrs, :entries, [])),
      do: :ok,
      else:
        error(
          :invalid_declaration_entry,
          "entries must be ordered templates or capability contributions",
          Map.get(attrs, :source)
        )
  end

  defp valid_entries?(entries) when is_list(entries),
    do: Enum.all?(entries, &(Template.valid?(&1) or CapabilityContribution.valid?(&1)))

  defp valid_entries?(_), do: false

  defp error(code, message, %SourceLocation{} = source) do
    if SourceLocation.valid?(source),
      do: {:error, Diagnostic.new!(code, message, source)},
      else: {:error, {code, message}}
  end

  defp error(code, message, _), do: {:error, {code, message}}
end
