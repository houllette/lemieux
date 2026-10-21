defmodule Lemieux.CLI.Learning.Reflection do
  @moduledoc """
  Host-owned, explicitly selected reflection over complete public task records.

  Reflection is independent of candidate adoption and sparse capture signals:
  successes, rejected probes and uncertainty can all teach later improvers.
  Every hypothesis cites existing JSON pointers into retained source bytes.
  Citation existence is mechanical; semantic entailment remains unconfirmed.
  Private confirmation grades never enter the input schema. Empty output is a
  legitimate abstention, not a fabricated lesson to satisfy an inventory gate.
  The supplied provider must already be controlled by the episode's outer
  allowance. No model work or executable adoption happens in `build/5`.
  """
  alias Lemieux.Agent.Session
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Promotion

  @record_keys ~w(task_request original selected public_grades refinement probes)
  @hypothesis_keys ~w(kind outcome mechanism applicability source_pointers)
  @system """
  You are Lemieux's experience reflector. Read the complete public task record,
  including original execution, every available probe, composition and selection.
  Retain concrete reusable workflow knowledge from successes, errors, rejected
  experiments and unresolved uncertainty. Describe conditions, observed behavior,
  a practical procedure or counterexample, and limitations. Separate observations
  from causal hypotheses. Do not copy task solutions, expected outputs, task IDs,
  benchmark-specific instructions or credentials into the lesson text. A public
  pass does not prove correctness or transfer. Adoption is not a prerequisite for
  a useful lesson; a rejected experiment is not proof its idea can never work.
  Return JSON only: {"lessons":[{"kind":"procedure"|"proposer_lesson",
  "outcome":"supported"|"rejected"|"contradicted"|"insufficient_evidence",
  "mechanism":"specific evidence-backed procedure or hypothesis, at most 4096 bytes",
  "applicability":["descriptive workflow/domain cues"],
  "source_pointers":["/original/transcript/0", "another existing JSON pointer"]}]}.
  Use at most four lessons, each with 1-8 real source pointers. A pointer must
  identify evidence for the statement, not merely a status label. Use an empty
  lessons list if the record supports no useful reusable observation. Never
  claim activation authority, independent confirmation or statistical efficacy.
  """

  @doc "Retains every conversational/tool entry; replaces repeated accounting/catalog metadata with hashed references."
  @spec project(observation :: map()) :: map()
  def project(observation) do
    entries = observation["transcript"] || []

    {metadata, trajectory} =
      Enum.split_with(
        entries,
        &(&1["type"] in ~w(request harness_snapshot extension_state run_evidence))
      )

    observation
    |> Map.take(~w(status finish_reason provider_error answer usage))
    |> Map.put("source_observation_sha256", Contract.digest(observation))
    |> Map.put("transcript", Enum.map(trajectory, &project_entry/1))
    |> Map.put(
      "metadata_references",
      Enum.map(
        metadata,
        &%{"id" => &1["id"], "type" => &1["type"], "sha256" => Contract.digest(&1)}
      )
    )
  end

  defp project_entry(%{"type" => "session", "payload" => payload} = entry),
    do:
      Map.put(
        entry,
        "payload",
        Map.take(payload, ~w(system model params reasoning_effort disabled_tools))
      )

  defp project_entry(entry), do: entry

  @spec distill(record :: map(), opts :: keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def distill(record, opts) do
    profile =
      Profile.quota(
        %{
          "execution" => "live",
          "model" => Keyword.fetch!(opts, :model),
          "tools" => [],
          "options" => %{
            "system" => @system,
            "max_turns" => 2,
            "max_tokens" => 8192,
            "max_cost_usd" => nil,
            "reasoning_effort" => Keyword.fetch!(opts, :effort),
            "temperature" => 0.0
          }
        },
        2
      )

    with :ok <- valid_record(record),
         {:ok, options, _} <-
           Profile.configure(profile, Keyword.take(opts, [:provider, :sessions_dir, :supervisor])),
         {:ok, observation} <-
           Session.run(
             %{
               cwd: Keyword.fetch!(opts, :cwd),
               prompt: Contract.encode!(record),
               timeout_ms: 480_000
             },
             options
           ),
         %{"lessons" => lessons} when is_list(lessons) and length(lessons) <= 4 <-
           JSON.decode!(observation["answer"]),
         true <- Enum.all?(lessons, &(valid_hypothesis(&1, record) == :ok)) do
      {:ok, lessons, observation}
    else
      _invalid -> {:error, :reflection_incomplete_or_invalid}
    end
  rescue
    _invalid_json -> {:error, :reflection_incomplete_or_invalid}
  end

  @spec retain(
          record :: map(),
          hypotheses :: [map()],
          task_id :: String.t(),
          store :: term(),
          authority :: function(),
          opts :: keyword()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def retain(record, hypotheses, task_id, store, authority, opts \\ []) do
    Enum.reduce_while(hypotheses, {:ok, []}, fn hypothesis, {:ok, ids} ->
      with {:ok, context} <- authority.(),
           {:ok, lesson} <- build(record, task_id, context, hypothesis, opts),
           {:ok, _receipt} <- Promotion.retain(store, lesson, authority) do
        {:cont, {:ok, ids ++ [lesson.id]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @spec build(
          record :: map(),
          task_id :: String.t(),
          context :: map(),
          hypothesis :: map(),
          opts :: keyword()
        ) :: {:ok, Lesson.t()} | {:error, term()}
  def build(record, task_id, context, hypothesis, opts \\ []) do
    with :ok <- valid_record(record), :ok <- valid_hypothesis(hypothesis, record) do
      bytes = Contract.encode!(record)

      reference =
        ArtifactReference.from_bytes("task_reflection", bytes,
          scope: context.scope,
          id: "public-record"
        )

      finding = "finding-" <> Contract.digest(hypothesis)

      with {:ok, bundle} <-
             Bundle.new(%{
               "id" => "reflection-" <> reference.sha256,
               "scope" => context.scope,
               "plan" => %{
                 "id" => "whole-record-reflection/v1",
                 "sha256" => Contract.sha256("whole-record-reflection/v1"),
                 "scope" => context.scope
               },
               "seeds" => [],
               "candidates" => [],
               "evaluations" => [],
               "exposures" => [],
               "raw" => [
                 %{
                   "id" => "record",
                   "scope" => context.scope,
                   "case_id" => task_id,
                   "reference" => ArtifactReference.to_map(reference)
                 }
               ],
               "derived" => [
                 %{"id" => finding, "scope" => context.scope, "source_references" => ["record"]}
               ],
               "artifacts" => [
                 %{
                   "id" => "record-bytes",
                   "scope" => context.scope,
                   "path" => "public-record.json",
                   "reference" => ArtifactReference.to_map(reference)
                 }
               ]
             }) do
        negative? = hypothesis["outcome"] in ~w(rejected contradicted)

        Lesson.new(bundle, %{reference.sha256 => bytes}, %{
          "key" =>
            "reflection-" <>
              Contract.digest(%{"source" => reference.sha256, "hypothesis" => hypothesis}),
          "kind" => hypothesis["kind"],
          "outcome" => hypothesis["outcome"],
          "qualification" => "unconfirmed",
          "applicability" => hypothesis["applicability"],
          "mechanism" => hypothesis["mechanism"],
          "supporting" => if(negative?, do: [], else: [finding]),
          "contradicting" => if(negative?, do: [finding], else: []),
          "candidate_ids" => [],
          "binding" => context.lesson_context,
          "provenance" => %{
            "actor" => "qualification-reflector",
            "record_sha256" => reference.sha256,
            "source_pointers" => hypothesis["source_pointers"],
            "semantic_entailment" => "unconfirmed"
          },
          "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "expires_at" => nil,
          "supersedes" => [],
          "source_lessons" => Enum.map(Keyword.get(opts, :source_lessons, []), &Lesson.to_map/1)
        })
      end
    end
  end

  defp valid_record(record) when is_map(record) do
    if Map.has_key?(record, "original") and Enum.all?(Map.keys(record), &(&1 in @record_keys)) and
         byte_size(Contract.encode!(record)) <= 786_432,
       do: :ok,
       else: {:error, :invalid_reflection_record}
  end

  defp valid_record(_record), do: {:error, :invalid_reflection_record}

  defp valid_hypothesis(hypothesis, record) when is_map(hypothesis) do
    with true <- Enum.sort(Map.keys(hypothesis)) == Enum.sort(@hypothesis_keys),
         true <- hypothesis["kind"] in ~w(procedure proposer_lesson),
         true <-
           hypothesis["outcome"] in ~w(supported rejected contradicted insufficient_evidence),
         true <- text?(hypothesis["mechanism"], 4096),
         cues when is_list(cues) and length(cues) in 1..8 <- hypothesis["applicability"],
         true <- Enum.all?(cues, &text?(&1, 256)),
         pointers when is_list(pointers) and length(pointers) in 1..8 <-
           hypothesis["source_pointers"],
         true <- Enum.all?(pointers, &(text?(&1, 256) and pointer?(record, &1))) do
      :ok
    else
      _invalid -> {:error, :invalid_reflection_hypothesis}
    end
  end

  defp valid_hypothesis(_hypothesis, _record), do: {:error, :invalid_reflection_hypothesis}

  defp pointer?(record, "/" <> pointer), do: present?(record, String.split(pointer, "/"))
  defp pointer?(_record, _pointer), do: false
  defp present?(_value, []), do: true

  defp present?(value, [key | rest]) when is_map(value) do
    key = key |> String.replace("~1", "/") |> String.replace("~0", "~")
    Map.has_key?(value, key) and present?(value[key], rest)
  end

  defp present?(value, [key | rest]) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 ->
        index < length(value) and present?(Enum.at(value, index), rest)

      _invalid ->
        false
    end
  end

  defp present?(_value, _keys), do: false

  defp text?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.trim(value) != ""
end
