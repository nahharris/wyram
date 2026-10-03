defmodule Mix.Tasks.Compile.Wyram do
  @moduledoc "Compiles the configured Wyram plugin catalog during Mix compilation."

  use Mix.Task.Compiler
  alias Wyram.Plugin.DSL.Entry

  @recursive true

  @impl true
  def run(_args) do
    case Entry.project_entry() do
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

      {:error, message} ->
        diagnostic = invalid_project_config(message)
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
