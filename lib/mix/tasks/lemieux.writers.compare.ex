defmodule Mix.Tasks.Lemieux.Writers.Compare do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Runs the offline isolated-writer comparison in a new receipt directory.

      mix lemieux.writers.compare --output /tmp/writer-comparison

  Uses only Scripted providers. Retains full transcripts, patches, reports and
  comparison.json. This fixture does not qualify hosted-model quality.
  """
  use Mix.Task
  alias Lemieux.Writers.Fixture
  @requirements ["app.start"]
  @shortdoc "Compare serial and parallel writers offline (experimental)"
  @impl Mix.Task
  def run(args) do
    {options, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    unless rest == [] and invalid == [] and is_binary(options[:output]),
      do: Mix.raise("usage: mix lemieux.writers.compare --output NEW_DIRECTORY")

    Mix.Task.run("app.start")

    case Fixture.run(Path.expand(options[:output])) do
      {:ok, receipt} -> Mix.shell().info(JSON.encode!(receipt))
      {:error, reason} -> Mix.raise("writer comparison failed: #{inspect(reason)}")
    end
  end
end
