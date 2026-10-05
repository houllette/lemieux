defmodule Lemieux.Learning.Proposer.Workspace do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The filesystem a proposer session works in: read-only evidence, one
  writable `proposal/` directory.

  Meta-Harness's ablation found that a proposer with filesystem access to
  prior candidates, scores and traces outperformed one shown a compressed
  summary; Lemieux's `Experience.Materializer` implements that layout for a
  host-authorized bundle. This module is the local, campaign-scoped version:
  it lays out the same kind of tree from in-memory evidence so a proposer
  session can `read` what it needs and `write` only its proposal. The
  evidence directories are sealed read-only while the session runs and
  unsealed afterwards so a test or a campaign can clean up; sealing is a
  belt over the validator's braces, not the boundary itself — the surface
  validator is.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan

  @type t :: %__MODULE__{root: Path.t(), proposal: Path.t(), sealed: [Path.t()]}

  @enforce_keys [:root, :proposal]
  defstruct [:root, :proposal, sealed: []]

  @max_excerpts 6

  @doc """
  Materializes one proposal workspace under `root` for `ordinal`.

  `inputs` carries: `:plan`, `:parent_bytes`, `:digest`, `:landscape`,
  `:operator`, `:evidence`, `:calibration`, `:evaluations`, `:artifacts`,
  `:instructions`.
  """
  @spec materialize(root :: Path.t(), ordinal :: pos_integer(), inputs :: map()) ::
          {:ok, t()} | {:error, term()}
  def materialize(root, ordinal, inputs) when is_binary(root) and is_integer(ordinal) do
    base = Path.join(root, "proposal-" <> String.pad_leading(Integer.to_string(ordinal), 3, "0"))
    write_tree(unique(base, 0), inputs)
  end

  @doc "Reads the proposal files a session wrote, if any."
  @spec proposal(workspace :: t()) ::
          {:ok, %{profile: map(), manifest: map(), bytes: binary()}} | {:error, term()}
  def proposal(%__MODULE__{proposal: proposal}) do
    with {:ok, bytes} <- read(Path.join(proposal, "profile.json"), :no_profile_written),
         {:ok, profile} <- decode(bytes, :invalid_profile_json),
         {:ok, manifest_bytes} <- read(Path.join(proposal, "manifest.json"), :no_manifest_written),
         {:ok, manifest} <- decode(manifest_bytes, :invalid_manifest_json) do
      {:ok, %{profile: profile, manifest: manifest, bytes: canonical(profile)}}
    end
  end

  @doc "Makes the evidence and parent trees read-only for the session."
  @spec seal(workspace :: t()) :: t()
  def seal(%__MODULE__{root: root} = workspace) do
    sealed =
      for name <- ~w(evidence parent), path = Path.join(root, name), File.dir?(path), do: path

    Enum.each(sealed, &chmod_tree(&1, 0o555, 0o444))
    %{workspace | sealed: sealed}
  end

  @doc "Restores write permission so the workspace can be cleaned up."
  @spec unseal(workspace :: t()) :: t()
  def unseal(%__MODULE__{sealed: sealed} = workspace) do
    Enum.each(sealed, &chmod_tree(&1, 0o755, 0o644))
    %{workspace | sealed: []}
  end

  # A resumed campaign may retry an ordinal whose earlier attempt left a
  # workspace behind; the old tree stays as evidence and the retry gets its
  # own directory.
  defp unique(base, 0), do: if(File.exists?(base), do: unique(base, 1), else: base)

  defp unique(base, n) do
    candidate = base <> "-r" <> Integer.to_string(n)
    if File.exists?(candidate), do: unique(base, n + 1), else: candidate
  end

  defp write_tree(dir, inputs) do
    plan = %Plan{} = Map.fetch!(inputs, :plan)
    proposal = Path.join(dir, "proposal")

    with :ok <- File.mkdir_p(Path.join(dir, "evidence/transcripts")),
         :ok <- File.mkdir_p(Path.join(dir, "parent")),
         :ok <- File.mkdir_p(proposal),
         :ok <- File.write(Path.join(dir, "README.md"), Map.get(inputs, :instructions, "")),
         :ok <- File.write(Path.join(dir, "plan.json"), Plan.encode!(plan)),
         :ok <-
           File.write(Path.join(dir, "parent/profile.json"), Map.fetch!(inputs, :parent_bytes)),
         :ok <- write_json(dir, "evidence/digest.json", Map.get(inputs, :digest, %{})),
         :ok <- write_json(dir, "evidence/landscape.json", Map.get(inputs, :landscape, %{})),
         :ok <-
           write_json(dir, "evidence/operator.json", %{
             "operator" => Map.get(inputs, :operator),
             "evidence" => Map.get(inputs, :evidence, %{})
           }),
         :ok <- write_json(dir, "evidence/calibration.json", Map.get(inputs, :calibration, %{})),
         :ok <- File.write(Path.join(dir, "evidence/summary.md"), summary(inputs)),
         :ok <- write_excerpts(dir, inputs) do
      {:ok, %__MODULE__{root: dir, proposal: proposal}}
    end
  end

  defp write_json(dir, name, value),
    do: File.write(Path.join(dir, name), JSON.encode!(value))

  defp write_excerpts(dir, inputs) do
    evaluations = Map.get(inputs, :evaluations, [])
    artifacts = Map.get(inputs, :artifacts, %{})

    wanted =
      excerpt_ids(Map.get(inputs, :evidence, %{}), Map.get(inputs, :parent_id), evaluations)

    evaluations
    |> Enum.filter(&(&1.id in wanted))
    |> Enum.take(@max_excerpts)
    |> Enum.reduce_while(:ok, fn %Evaluation{} = evaluation, :ok ->
      halt_on_error(write_excerpt(dir, evaluation, artifacts))
    end)
  end

  defp write_excerpt(dir, evaluation, artifacts) do
    case Digest.entries(evaluation, artifacts) do
      nil ->
        write_reports(dir, evaluation, artifacts)

      entries ->
        name = safe_name(evaluation.id) <> ".json"
        write_json(dir, Path.join("evidence/transcripts", name), excerpt(entries, evaluation))
    end
  end

  defp excerpt(entries, evaluation) do
    entries
    |> Digest.excerpt(max_bytes: 16_000)
    |> Map.merge(%{
      "evaluation_id" => evaluation.id,
      "candidate_id" => evaluation.candidate_id,
      "case_id" => evaluation.case_id,
      "objectives" => evaluation.objectives,
      "observations" => evaluation.observations
    })
  end

  # A meta-level evaluation references an inner campaign report rather than
  # a transcript; it is written as-is, bounded, so the proposer can read it.
  defp write_reports(dir, evaluation, artifacts) do
    evaluation.artifacts
    |> Enum.reject(&(&1.kind == "transcript"))
    |> Enum.reduce_while(:ok, fn reference, :ok ->
      halt_on_error(
        write_report(dir, evaluation, reference, Map.get(artifacts, reference.sha256))
      )
    end)
  end

  defp write_report(_dir, _evaluation, _reference, nil), do: :ok

  defp write_report(dir, evaluation, reference, bytes) do
    name = safe_name(evaluation.id) <> "-" <> safe_name(reference.kind) <> ".md"
    path = Path.join([dir, "evidence", "transcripts", name])
    File.write(path, binary_part(bytes, 0, min(byte_size(bytes), 64_000)))
  end

  defp halt_on_error(:ok), do: {:cont, :ok}
  defp halt_on_error(error), do: {:halt, error}

  # Evidence names the evaluations an operator selected. An operator with no
  # failures to point at (a parent that passed everything, or a consolidate
  # edit) still leaves the proposer reading its parent's own traces rather
  # than nothing: the meta level's inner reports arrive this way.
  defp excerpt_ids(evidence, parent_id, evaluations) do
    direct = List.wrap(evidence["evaluation_ids"])

    pairs =
      evidence
      |> Map.get("pairs", [])
      |> Enum.flat_map(&[&1["target_evaluation_id"], &1["reference_evaluation_id"]])

    case Enum.filter(direct ++ pairs, &is_binary/1) do
      [] -> evaluations |> Enum.filter(&(&1.candidate_id == parent_id)) |> Enum.map(& &1.id)
      ids -> ids
    end
  end

  defp summary(inputs) do
    digest = Map.get(inputs, :digest, %{})
    clusters = Map.get(digest, "clusters", [])

    cluster_lines =
      Enum.map_join(clusters, "\n", fn cluster ->
        signature = cluster["signature"]

        "- #{cluster["count"]}× cause=#{signature["cause"]} status=#{signature["causal_status"]} " <>
          "mechanism=#{signature["mechanism"]} cases=#{Enum.join(cluster["case_ids"], ",")} " <>
          "candidates=#{Enum.join(cluster["candidate_ids"], ",")}"
      end)

    """
    # Evidence summary

    Operator: #{Map.get(inputs, :operator)}
    Calibration status: #{get_in(inputs, [:calibration, "status"]) || "unknown"}

    ## Failure clusters (most support first)
    #{if cluster_lines == "", do: "(no development failures recorded)", else: cluster_lines}

    ## Files
    - plan.json: the frozen search contract (mutation_surface lists the only paths you may change)
    - parent/profile.json: the document you are editing; copy it whole into proposal/profile.json and apply your edit
    - evidence/digest.json: every development evaluation's failure signature
    - evidence/landscape.json: every prior candidate, what it changed, how it scored, whether it was accepted
    - evidence/operator.json: the evidence selected for this proposal
    - evidence/transcripts/*.json: bounded excerpts of the transcripts behind that evidence
    - evidence/calibration.json: how well earlier predictions matched outcomes
    """
  end

  defp read(path, missing) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, missing}
      {:error, reason} -> {:error, {:proposal_unreadable, reason}}
    end
  end

  defp decode(bytes, invalid) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> {:error, invalid}
    end
  end

  defp canonical(map), do: Contract.encode!(map)

  defp safe_name(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp chmod_tree(path, dir_mode, file_mode) do
    if File.dir?(path) do
      path |> File.ls!() |> Enum.each(&chmod_tree(Path.join(path, &1), dir_mode, file_mode))
      File.chmod!(path, dir_mode)
    else
      File.chmod!(path, file_mode)
    end
  end
end
