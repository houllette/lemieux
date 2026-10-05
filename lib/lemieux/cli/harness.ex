defmodule Lemieux.CLI.Harness do
  @moduledoc """
  Standalone inspection and deterministic materialization for harness learning.

  It verifies the same public library contracts an embedding host uses. No
  command can activate an asset, inspect a hidden corpus, or acquire artifacts
  from a remote service.
  """

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Contract
  alias Lemieux.Evidence.Run
  alias Lemieux.Experiment.Plan, as: ExperimentPlan
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Materializer
  alias Lemieux.Learning.Overlay

  @types ~w(snapshot run bundle discovery-plan candidate evaluation frontier state exposure experiment-plan)

  @doc "Runs a harness-learning inspection command."
  @spec run(argv :: [String.t()]) :: :ok | {:error, pos_integer()}
  def run(["verify", type, path]) when type in @types do
    with {:ok, body} <- File.read(path),
         :ok <- verify(type, body) do
      IO.puts("verified #{type} #{path}")
      :ok
    else
      {:error, reason} -> error("could not verify #{type} #{path}: #{inspect(reason)}")
    end
  end

  def run(["export", archive_dir, candidate_id | flags]) do
    {parsed, _rest, invalid} =
      OptionParser.parse(flags, strict: [to: :string, unconfirmed: :boolean, force: :boolean])

    path = Keyword.get(parsed, :to, Path.join(".lmx", Overlay.filename()))

    with [] <- invalid,
         {:ok, overlay} <- Overlay.from_archive(archive_dir, candidate_id),
         :ok <-
           Overlay.export(overlay, path,
             unconfirmed: Keyword.get(parsed, :unconfirmed, false),
             force: Keyword.get(parsed, :force, false)
           ) do
      IO.puts("exported #{overlay.qualification} overlay #{overlay.sha256} to #{path}")

      case descriptions_note(overlay, path, personal_overlay()) do
        nil -> :ok
        note -> IO.puts(:stderr, "lmx: " <> note)
      end

      IO.puts("activation is your review of that file; remove it or revert it to roll back")
      :ok
    else
      [{flag, _} | _] ->
        error("unrecognised export option #{flag}")

      {:error, {:unconfirmed_overlay, qualification}} ->
        error(
          "candidate #{candidate_id} is #{qualification}; pass --unconfirmed to export a development-only overlay"
        )

      {:error, reason} ->
        error("could not export overlay: #{inspect(reason)}")
    end
  end

  def run(["materialize", bundle_path, artifact_dir, destination]) do
    with {:ok, body} <- File.read(bundle_path),
         {:ok, bundle} <- Bundle.decode(body),
         {:ok, artifacts} <- read_artifacts(bundle, artifact_dir),
         {:ok, destination} <- Materializer.materialize(bundle, artifacts, destination) do
      IO.puts(destination)
      :ok
    else
      {:error, reason} -> error("could not materialize bundle: #{inspect(reason)}")
    end
  end

  def run(_argv) do
    IO.puts(:stderr, usage())
    {:error, 1}
  end

  @doc false
  # What an export says about the tool descriptions it wrote, or `nil` when
  # they will be applied — the file is `personal`, your own overlay — or there
  # are none. The default destination is the repository's `.lmx/harness.json`,
  # a file reviewed and committed like any other change, and since a
  # repository may no longer re-describe tools (`Lemieux.Learning.Overlay`,
  # "Whose overlay may do what") it is read for its system-prompt text alone.
  # An export that wrote descriptions there and said nothing left a person
  # believing a learned improvement was in force when `lmx` was dropping it
  # at every start.
  @spec descriptions_note(overlay :: Overlay.t(), path :: Path.t(), personal :: Path.t()) ::
          String.t() | nil
  def descriptions_note(%Overlay{tool_descriptions: descriptions}, _path, _personal)
      when map_size(descriptions) == 0,
      do: nil

  def descriptions_note(%Overlay{} = overlay, path, personal) do
    # `path` as the export wrote it: a `~` that reached here unexpanded is a
    # directory of that name, not the home directory.
    if path |> Path.absname() |> Path.expand() == Path.expand(personal) do
      nil
    else
      tools = overlay.tool_descriptions |> Map.keys() |> Enum.sort() |> Enum.join(", ")
      own = Path.join("~/.lmx", Overlay.filename())
      repository = Path.join(".lmx", Overlay.filename())

      rule =
        "your own #{own} may describe tools: a repository's #{repository} adds " <>
          "system-prompt text and nothing else"

      if overlay.system_suffix in [nil, ""],
        do:
          "nothing in this overlay applies from #{path}. It only describes tools " <>
            "(#{tools}), and only #{rule}. To apply it, export it with --to #{own} instead",
        else:
          "its descriptions of #{tools} do not apply from #{path}. Only #{rule}. " <>
            "To apply them, export it with --to #{own} instead"
    end
  end

  # Your own overlay: where `Lemieux.Extensions.Workspace.Discovery` reads one
  # that may describe tools.
  defp personal_overlay, do: Path.expand(Path.join("~/.lmx", Overlay.filename()))

  defp verify("snapshot", body), do: decoded(Snapshot.decode(body))
  defp verify("run", body), do: decoded(Run.decode(body))
  defp verify("bundle", body), do: decoded(Bundle.decode(body))
  defp verify("discovery-plan", body), do: decoded(Plan.decode(body))
  defp verify("experiment-plan", body), do: decoded(ExperimentPlan.decode(body))
  defp verify("candidate", body), do: verify_map(body, &Candidate.verify/1)
  defp verify("evaluation", body), do: verify_map(body, &Evaluation.verify/1)
  defp verify("frontier", body), do: verify_map(body, &Frontier.verify/1)
  defp verify("state", body), do: verify_map(body, &State.verify/1)
  defp verify("exposure", body), do: decoded(Exposure.decode(body))

  defp decoded({:ok, _object}), do: :ok
  defp decoded({:error, reason}), do: {:error, reason}

  defp verify_map(body, verifier) do
    with {:ok, map} <- Contract.decode(body), do: verifier.(map)
  end

  defp read_artifacts(bundle, directory) do
    Enum.reduce_while(bundle.artifacts, {:ok, %{}}, fn descriptor, {:ok, found} ->
      reference = descriptor["reference"]

      paths =
        [reference["sha256"], reference["id"]]
        |> Enum.filter(&safe_artifact_filename?/1)
        |> Enum.map(&Path.join(directory, &1))

      case read_first(paths) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(found, reference["id"], bytes)}}
        {:error, reason} -> {:halt, {:error, {reference["id"], reason}}}
      end
    end)
  end

  defp read_first([]), do: {:error, :enoent}

  defp read_first([path | rest]) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> read_first(rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_artifact_filename?(name) when is_binary(name),
    do: name not in ["", ".", ".."] and Path.basename(name) == name

  defp safe_artifact_filename?(_name), do: false

  defp error(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end

  defp usage do
    """
    Usage:
      lmx harness verify TYPE FILE
      lmx harness materialize BUNDLE ARTIFACT_DIR DESTINATION
      lmx harness export CAMPAIGN_DIR CANDIDATE_ID [--to PATH] [--unconfirmed] [--force]

    TYPE is one of: #{Enum.join(@types, ", ")}.
    Artifact files are named by reference id or SHA-256.
    export writes .lmx/harness.json unless --to names another file. A
    repository's overlay adds system-prompt text only; tool descriptions
    apply from your own ~/.lmx/harness.json.
    """
  end
end
