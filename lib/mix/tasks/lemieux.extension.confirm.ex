defmodule Mix.Tasks.Lemieux.Extension.Confirm do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Preregisters, runs and exports one independent extension confirmation.

      mix lemieux.extension.confirm prepare CONFIG.exs NEW_DIRECTORY
      mix lemieux.extension.confirm run DIRECTORY EXPECTED_SHA256 [--allow-live]
      mix lemieux.extension.confirm export DIRECTORY EXPECTED_SHA256 NEW_PACKAGE

  Prepare executes a trusted explicit config returning `control:` and
  `candidate:` frozen Build structs, `corpus:`, `experiment:` attribute map,
  `evaluator_root:` and optional `discovery_candidate:`. See
  `Lemieux.Learning.Extension.Confirmation` for profiles, thresholds and exposure rules.
  Retain the printed digest outside the confirmation directory. Runs are single
  use; even interrupted attempts consume exposure. Live runs require the explicit
  flag and preregistered budgets. No option uploads evidence or activates code.

  Export copies only passing candidate source. A content-free confirmation
  receipt is written beside it as NEW_PACKAGE.confirmation.json. Keep private
  experiment evidence separately; a receipt is an integrity reference, not a
  signature or proof of efficacy on tasks outside its declared evaluation.
  """
  use Mix.Task

  alias Lemieux.Learning.Extension.Confirmation
  alias Lemieux.Learning.Extension.Tree

  @shortdoc "Confirm a frozen extension on independent cases and export its exact source (experimental)"
  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    execute(args)
  end

  defp execute(["prepare", config_path, destination]) do
    {config, _bindings} = Code.eval_file(config_path)

    result =
      Confirmation.prepare(
        destination,
        Keyword.fetch!(config, :control),
        Keyword.fetch!(config, :candidate),
        Keyword.fetch!(config, :corpus),
        Keyword.fetch!(config, :experiment),
        Keyword.take(config, [:evaluator_root, :evaluator_runtime, :discovery_candidate])
      )

    case result do
      {:ok, handle} ->
        Mix.shell().info("Preregistered: #{handle.root}\nSHA-256: #{handle.sha256}")

      error ->
        fail(error)
    end
  end

  defp execute(["run", directory, digest | flags]) when flags in [[], ["--allow-live"]] do
    with {:ok, handle} <- Confirmation.open(directory, digest),
         {:ok, result} <- Confirmation.run(handle, allow_live: flags != []) do
      Mix.shell().info("Confirmation: #{result["verdict"]}. Private evidence: #{handle.root}")
    else
      error -> fail(error)
    end
  end

  defp execute(["export", directory, digest, destination]) do
    receipt_path = destination <> ".confirmation.json"
    if File.exists?(receipt_path), do: Mix.raise("Receipt destination exists: #{receipt_path}")

    with {:ok, handle} <- Confirmation.open(directory, digest),
         {:ok, receipt} <- Confirmation.export(handle, destination),
         :ok <- Tree.write(receipt_path, receipt) do
      Mix.shell().info(
        "Exported confirmed source: #{destination}\nEvidence receipt: #{receipt_path}"
      )
    else
      error -> fail(error)
    end
  end

  defp execute(_args),
    do: Mix.raise("Usage: mix lemieux.extension.confirm prepare|run|export (see mix help)")

  @spec fail(error :: term()) :: no_return()
  defp fail(error), do: Mix.raise("Extension confirmation failed: #{inspect(error)}")
end
