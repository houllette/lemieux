defmodule Mix.Tasks.Lmx.Upgrade.Draft do
  @shortdoc "Inspects two releases and writes an unreviewed upgrade decision"
  @moduledoc """
  Generates review work from actual artifacts, without approving hot loading.

      mix lmx.upgrade.draft --from /tmp/previous --to /tmp/candidate \\
        --output upgrades/0.1.1.exs

  Prints the observed identities/module diff as JSON. The output plan is never
  overwritten and remains unreviewed. Run on each build host, carry its exact
  predecessor build identity into that platform's decision, review code/state,
  and qualify the actual archives before publication.
  """
  use Mix.Task
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [from: :string, to: :string, output: :string])

    if rest != [] or invalid != [] or !opts[:from] or !opts[:to],
      do: Mix.raise("provide --from OLD_ROOT --to NEW_ROOT [--output FILE]")

    report = Lmx.UpgradePlan.report(opts[:from], opts[:to])
    Mix.shell().info(JSON.encode!(report))

    if output = opts[:output] do
      draft = Lmx.UpgradePlan.draft(report)
      body = inspect(draft, pretty: true, limit: :infinity, printable_limit: :infinity)

      case File.write(output, body <> "\n", [:exclusive]) do
        :ok ->
          Mix.shell().info("Wrote unreviewed #{output}; review every platform before release")

        {:error, reason} ->
          Mix.raise("cannot write #{output}: #{inspect(reason)}")
      end
    end
  end
end
