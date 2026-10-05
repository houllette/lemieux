defmodule Mix.Tasks.Lemieux.Extension.Export do
  @shortdoc "Exports explicit native agent extension sources to a new Mix project directory (experimental)"
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Copies the files listed in `lemieux-extension.json` without executing code.

      mix lemieux.extension.export path/to/extension path/to/export

  The source must already be a Mix project. The destination must not exist.
  The receipt verifies file identity only; export does not qualify, publish or
  install the extension. Use a path/Git dependency to consume the resulting
  project. Ecosystem skills/commands remain plugins, a different format.
  """

  use Mix.Task

  alias Lemieux.Learning.Extension.Export

  @impl true
  def run([source, destination]) do
    case Export.export(source, destination) do
      {:ok, receipt} ->
        Mix.shell().info(
          "Exported #{receipt["module"]} to #{Path.expand(destination)} (unassessed)"
        )

      {:error, reason} ->
        Mix.raise("Extension export failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix lemieux.extension.export SOURCE DESTINATION")
end
