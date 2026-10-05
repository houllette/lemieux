defmodule Mix.Tasks.Lemieux.Extension.Compare do
  @shortdoc "Plans or runs a user-selected model/effort comparison for an extension (experimental)"
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Uses a trusted workbench configuration and an explicit JSON shortlist:

      mix lemieux.extension.compare bench/workbench.exs bench/models.json
      mix lemieux.extension.compare bench/workbench.exs bench/models.json --allow-live

  Configuration adds `:search_provider`, the same runtime connection used by
  the configured agents. Optional `:available_models` is a host-supplied inventory
  for that connection. The first configured agent is the comparison baseline.
  Selections are `[{"model":"provider:id","efforts":["default","high"]}]`.
  Only those pairs are added. Repeating the command reuses identical variants.

  The default plans without generation. `--allow-live` dispatches with existing
  workbench budgets; `--run` dispatches scripted configurations only. The trusted
  configuration itself executes when loaded. The command records development
  comparisons and does not choose or qualify a winner.
  """

  use Mix.Task
  alias Lemieux.Learning.Extension.ModelSearch
  alias Lemieux.Learning.Extension.Workbench
  alias Lemieux.Learning.Extension.Workbench.View

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: [allow_live: :boolean, run: :boolean]) do
      {flags, [config_path, selection_path], []} ->
        Mix.Task.run("app.start")
        {config, _} = Code.eval_file(config_path)
        result = compare(config, selection_path, flags)

        case result do
          :ok -> :ok
          {:error, reason} -> Mix.raise("Model comparison failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise(
          "Usage: mix lemieux.extension.compare CONFIG.exs SELECTIONS.json [--allow-live | --run]"
        )
    end
  end

  defp compare(config, path, flags) do
    with {:ok, bytes} <- File.read(path),
         {:ok, selections} <- JSON.decode(bytes),
         {:ok, provider} <- Keyword.fetch(config, :search_provider),
         {:ok, state} <- Workbench.open(config),
         [{base, _module, _opts} | _] = config[:agents],
         {:ok, state, names} <-
           ModelSearch.add(
             state,
             base,
             provider,
             selections,
             Keyword.take(config, [:available_models])
           ),
         {:ok, state} <- Workbench.select(state, state.project["selected_cases"], [base | names]) do
      Mix.shell().info(View.project(state))
      Mix.shell().info("Model/effort candidates: #{JSON.encode!(selections)}")

      Mix.shell().info(
        "Catalog configuration is not proof of account access. No automatic winner."
      )

      dispatch(state, flags)
    else
      :error -> {:error, :search_provider_required}
      error -> error
    end
  end

  defp dispatch(state, flags) do
    if flags[:allow_live] == true or flags[:run] == true do
      with {:ok, report, id} <- Workbench.run(state, allow_live: flags[:allow_live] == true) do
        Mix.shell().info("Saved run #{id}\n#{View.summary(report)}")
        :ok
      end
    else
      Mix.shell().info("Plan only. Use --allow-live for a live run after reviewing the limits.")
      :ok
    end
  end
end
