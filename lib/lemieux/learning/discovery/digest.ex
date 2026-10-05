defmodule Lemieux.Learning.Discovery.Digest do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Compresses evaluation transcripts into clustered failure signatures.

  A proposer that reads raw trajectories pays for every token twice: once to
  read them and once in the noise they add to its edit. Self-Harness
  (arXiv 2606.09498) instead groups failures by a three-part signature — what
  the verifier rejected, how the agent's own behavior contributed, and which
  reusable mechanism was involved — and proposes one minimal edit per cluster.
  HarnessX's digester does the same compression before its planner runs. This
  module is that stage for Lemieux: pure, bounded, and grounded in facts the
  transcript already records (grader verdicts, stop reasons, tool outcome
  classes, changed paths), never in a model's opinion of what went wrong.

  Mechanisms are named heuristics over recorded tool outcomes, in a fixed
  priority order, so two people reading the same transcript get the same
  label. They are a triage index for the proposer, not a diagnosis: the
  proposer still reads the excerpts behind the cluster it chooses.
  """

  alias Lemieux.Entry
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Reflection

  @mechanisms ~w(
    wrote_outside_allowlist model_output_limit answered_without_tools edit_mismatch tool_error_loop
    denied_tool command_timeout output_limit repeated_tool_wave
    no_verification_after_change unknown none
  )

  @doc "The closed mechanism vocabulary, in priority order."
  @spec mechanisms() :: [String.t()]
  def mechanisms, do: @mechanisms

  @doc """
  Computes one evaluation's signature from its recorded facts and, when
  available, its decoded transcript entries (JSON maps as retained by the
  evaluator).
  """
  @spec signature(evaluation :: Evaluation.t(), entries :: [map()] | nil, policy :: Policy.t()) ::
          map()
  def signature(%Evaluation{} = evaluation, entries, policy) when is_map(policy) do
    success = Policy.success?(evaluation, policy)
    cause = cause(evaluation, success)
    entries = entries || []

    %{
      "cause" => cause,
      "causal_status" => causal_status(evaluation),
      "mechanism" => mechanism(cause, evaluation, entries),
      "success" => success,
      "candidate_id" => evaluation.candidate_id,
      "case_id" => evaluation.case_id,
      "evaluation_id" => evaluation.id,
      "transcript_available" => entries != []
    }
  end

  @doc """
  Builds the digest over every development evaluation: per-evaluation
  signatures, clusters ordered by support, and per-candidate and per-case
  tallies. `artifacts` maps SHA-256 to retained transcript bytes.
  """
  @spec build(
          plan :: Plan.t(),
          evaluations :: [Evaluation.t()],
          artifacts :: %{String.t() => binary()},
          policy :: Policy.t()
        ) :: map()
  def build(%Plan{}, evaluations, artifacts, policy)
      when is_list(evaluations) and is_map(artifacts) and is_map(policy) do
    signatures =
      evaluations
      |> Enum.filter(&Policy.development?/1)
      |> Enum.map(&signature(&1, entries(&1, artifacts), policy))

    failures = Enum.reject(signatures, & &1["success"])

    clusters =
      failures
      |> Enum.group_by(&Map.take(&1, ~w(cause causal_status mechanism)))
      |> Enum.map(fn {key, members} ->
        %{
          "signature" => key,
          "count" => length(members),
          "evaluation_ids" => members |> Enum.map(& &1["evaluation_id"]) |> Enum.sort(),
          "candidate_ids" =>
            members |> Enum.map(& &1["candidate_id"]) |> Enum.uniq() |> Enum.sort(),
          "case_ids" => members |> Enum.map(& &1["case_id"]) |> Enum.uniq() |> Enum.sort()
        }
      end)
      |> Enum.sort_by(&{-&1["count"], &1["signature"]["mechanism"], &1["signature"]["cause"]})

    %{
      "schema_version" => 1,
      "signatures" => Map.new(signatures, &{&1["evaluation_id"], &1}),
      "clusters" => clusters,
      "by_candidate" => tally(signatures, "candidate_id"),
      "by_case" => tally(signatures, "case_id"),
      "counts" => %{
        "evaluations" => length(signatures),
        "failures" => length(failures),
        "clusters" => length(clusters)
      }
    }
  end

  @doc """
  A bounded evidence excerpt for one transcript, reusing the reflection
  projection so redaction and clipping rules are shared. `max_bytes` bounds
  the projection (default 24 kB).
  """
  @spec excerpt(entries :: [map()], opts :: keyword()) :: map()
  def excerpt(entries, opts \\ []) when is_list(entries) and is_list(opts) do
    entries
    |> Enum.map(&Entry.from_json!/1)
    |> Reflection.gather(max_evidence_bytes: Keyword.get(opts, :max_bytes, 24_000))
    |> Map.take(~w(entry_count event_counts tool_usage coverage events))
  end

  @doc "Decodes the transcript entries retained for an evaluation, if any."
  @spec entries(evaluation :: Evaluation.t(), artifacts :: %{String.t() => binary()}) ::
          [map()] | nil
  def entries(%Evaluation{artifacts: references}, artifacts) when is_map(artifacts) do
    references
    |> Enum.find(&(&1.kind == "transcript"))
    |> case do
      nil -> nil
      reference -> decode_entries(Map.get(artifacts, reference.sha256))
    end
  end

  defp decode_entries(nil), do: nil

  defp decode_entries(bytes) when is_binary(bytes) do
    case JSON.decode(bytes) do
      {:ok, entries} when is_list(entries) -> entries
      _invalid -> nil
    end
  end

  defp cause(%Evaluation{safety: %{"passed" => false}}, _success), do: "safety_violation"
  defp cause(%Evaluation{terminal: false}, _success), do: "runtime_failed"
  defp cause(_evaluation, true), do: "passed"

  defp cause(%Evaluation{observations: observations}, false) do
    case observations["finish_reason"] do
      reason when reason in [":benchmark_timeout", ":agent_timeout"] -> "timeout"
      ":length" -> "output_limit"
      ":max_turns" -> "budget_stopped"
      ":no_progress" -> "budget_stopped"
      ":error" -> provider_cause(observations)
      reason when is_binary(reason) and reason != "" -> budget_or_grader(reason)
      _unknown -> "grader_failed"
    end
  end

  # A run that ended on a provider failure is clustered by what the provider did
  # rather than lumped in with wrong answers: a campaign whose failures are all
  # `provider_timeout` is telling its operator to fix the connection, and one whose
  # failures are `grader_failed` is telling them about the candidate.
  defp provider_cause(observations) do
    case get_in(observations, ["provider_error", "category"]) do
      category when is_binary(category) and category != "" -> "provider_" <> category
      _unclassified -> "provider_error"
    end
  end

  defp budget_or_grader(reason) do
    if String.starts_with?(reason, "{:budget"), do: "budget_stopped", else: "grader_failed"
  end

  defp causal_status(%Evaluation{observations: observations}),
    do: causal_status_for(observations["finish_reason"])

  defp causal_status_for(nil), do: "unknown"
  defp causal_status_for(":end_turn"), do: "end_turn"
  defp causal_status_for(":stop"), do: "end_turn"
  defp causal_status_for(":length"), do: "output_limit"
  defp causal_status_for(":max_turns"), do: "max_turns"
  defp causal_status_for(":no_progress"), do: "no_progress"
  defp causal_status_for(":hook_failed"), do: "hook_denied"
  defp causal_status_for(":cancelled"), do: "cancelled"
  defp causal_status_for(":error"), do: "error"
  defp causal_status_for(":timeout"), do: "timeout"

  defp causal_status_for(reason) when reason in [":benchmark_timeout", ":agent_timeout"],
    do: "timeout"

  defp causal_status_for(reason) when is_binary(reason),
    do: if(String.starts_with?(reason, "{:budget"), do: "budget", else: "unknown")

  defp causal_status_for(_other), do: "unknown"

  defp mechanism("passed", _evaluation, _entries), do: "none"
  defp mechanism("safety_violation", _evaluation, _entries), do: "wrote_outside_allowlist"
  defp mechanism("output_limit", _evaluation, _entries), do: "model_output_limit"

  defp mechanism(_cause, evaluation, entries) do
    results = Enum.filter(entries, &(&1["type"] == "tool_result"))
    payloads = Enum.map(results, &(&1["payload"] || %{}))

    cond do
      entries != [] and results == [] -> "answered_without_tools"
      error_loop?(payloads, "edit") -> "edit_mismatch"
      error_loop?(payloads, nil) -> "tool_error_loop"
      true -> outcome_mechanism(payloads, evaluation)
    end
  end

  # The lower-priority mechanisms, read off individual tool outcomes once no
  # loop-shaped signature has claimed the transcript.
  defp outcome_mechanism(payloads, evaluation) do
    cond do
      outcome?(payloads, "denied") -> "denied_tool"
      outcome?(payloads, "timeout") -> "command_timeout"
      output_limit?(payloads) -> "output_limit"
      evaluation.observations["finish_reason"] == ":no_progress" -> "repeated_tool_wave"
      unverified_change?(payloads) -> "no_verification_after_change"
      true -> "unknown"
    end
  end

  defp outcome?(payloads, outcome), do: Enum.any?(payloads, &(&1["outcome"] == outcome))

  defp output_limit?(payloads),
    do: Enum.any?(payloads, &(get_in(&1, ["structured_content", "status"]) == "output_limit"))

  defp error_loop?(payloads, name) do
    payloads
    |> Enum.filter(&(&1["error"] == true and (is_nil(name) or &1["name"] == name)))
    |> Enum.group_by(& &1["name"])
    |> Enum.any?(fn {_name, errors} -> length(errors) >= 3 end)
  end

  # A write or edit that is never followed by a read or a command left the
  # agent trusting its own claim; that is the most common shape of a failed
  # grader after a confident answer.
  defp unverified_change?(payloads) do
    names = Enum.map(payloads, & &1["name"])

    case Enum.find_index(Enum.reverse(names), &(&1 in ["write", "edit"])) do
      nil ->
        false

      from_end ->
        from_end == 0 or
          not Enum.any?(Enum.take(Enum.reverse(names), from_end), &(&1 in ["bash", "read"]))
    end
  end

  defp tally(signatures, key) do
    signatures
    |> Enum.group_by(& &1[key])
    |> Map.new(fn {id, rows} ->
      {id,
       %{
         "successes" => Enum.count(rows, & &1["success"]),
         "failures" => Enum.count(rows, &(not &1["success"])),
         "mechanisms" =>
           rows
           |> Enum.reject(& &1["success"])
           |> Enum.frequencies_by(& &1["mechanism"])
       }}
    end)
  end
end
