defmodule Mix.Tasks.Lemieux.Extension.Freeze do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Freezes a trusted extension and its execution profile.

      mix lemieux.extension.freeze freeze.exs NEW_DIRECTORY

  The explicit Elixir config returns `source: path`, `profile: json_map`, and
  optional `runtime_paths:` / `runtime_assets:` (see `Lemieux.Learning.Extension.Build`).
  Paths resolve from the current Mix project. This executes configuration code,
  copies declared files and dependency runtime bytes, and prints the digest to
  retain separately. It does not run the extension or make model calls.
  """
  use Mix.Task

  alias Lemieux.Learning.Extension.Build

  @shortdoc "Freeze extension source, profile and dependency runtime (experimental)"
  @impl true
  def run([config_path, destination]) do
    Mix.Task.run("app.start")
    {config, _bindings} = Code.eval_file(config_path)

    case Build.freeze(
           Keyword.fetch!(config, :source),
           destination,
           Keyword.fetch!(config, :profile),
           Keyword.take(config, [:runtime_paths, :runtime_assets])
         ) do
      {:ok, build} -> Mix.shell().info("Frozen build: #{build.root}\nSHA-256: #{build.sha256}")
      {:error, reason} -> Mix.raise("Cannot freeze extension: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix lemieux.extension.freeze CONFIG.exs NEW_DIRECTORY")
end
