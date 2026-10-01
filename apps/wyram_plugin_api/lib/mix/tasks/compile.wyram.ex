defmodule Mix.Tasks.Compile.Wyram do
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    case plugin_entry(Mix.Project.config()[:wyram_plugin]) do
      :none ->
        {:noop, []}

      {:ok, entry} ->
        case Wyram.Plugin.Compiler.compile_entry(entry) do
          {:ok, _artifact} ->
            {:ok, []}

          {:error, diagnostics} ->
            Enum.each(
              diagnostics,
              &Mix.shell().error("#{&1.source.file}:#{&1.source.line}: #{&1.message}")
            )

            {:error, Enum.map(diagnostics, &mix_diagnostic/1)}
        end

      {:error, diagnostic} ->
        Mix.shell().error("mix.exs: #{diagnostic.message}")
        {:error, [mix_diagnostic(diagnostic)]}
    end
  end

  @doc false
  @impl true
  def clean do
    File.rm(Wyram.Plugin.Compiler.catalog_path())
    :ok
  end

  defp plugin_entry(nil), do: :none

  defp plugin_entry(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:entry] == [] and
         length(options) == length(Enum.uniq(Keyword.keys(options))) do
      case Keyword.get(options, :entry) do
        entry when is_atom(entry) -> {:ok, entry}
        _ -> {:error, invalid_project_config(":wyram_plugin requires an :entry module")}
      end
    else
      {:error, invalid_project_config(":wyram_plugin accepts only a unique :entry option")}
    end
  end

  defp plugin_entry(%{entry: entry} = options) when map_size(options) == 1 and is_atom(entry),
    do: {:ok, entry}

  defp plugin_entry(_),
    do: {:error, invalid_project_config(":wyram_plugin must contain only an :entry module")}

  defp invalid_project_config(message) do
    Wyram.Plugin.Diagnostic.new!(
      :invalid_plugin_project_config,
      message,
      %Wyram.Plugin.SourceLocation{file: "mix.exs", line: 1}
    )
  end

  defp mix_diagnostic(diagnostic) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "wyram",
      file: diagnostic.source.file,
      severity: :error,
      message: diagnostic.message,
      position: diagnostic.source.line
    }
  end
end
