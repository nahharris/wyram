defmodule Mix.Tasks.Compile.WyramPrepare do
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    case File.rm(Wyram.Plugin.Compiler.catalog_path()) do
      :ok ->
        {:ok, []}

      {:error, :enoent} ->
        {:noop, []}

      {:error, reason} ->
        diagnostic =
          Wyram.Plugin.Diagnostic.new!(
            :catalog_invalidation_failed,
            "cannot remove the previous plugin catalog: #{inspect(reason)}",
            %Wyram.Plugin.SourceLocation{file: "mix.exs", line: 1}
          )

        {:error,
         [
           %Mix.Task.Compiler.Diagnostic{
             compiler_name: "wyram_prepare",
             file: diagnostic.source.file,
             severity: :error,
             message: diagnostic.message,
             position: diagnostic.source.line
           }
         ]}
    end
  end

  @impl true
  def clean do
    File.rm(Wyram.Plugin.Compiler.catalog_path())
    :ok
  end
end
