defmodule Lemieux.CLI.Learning.AssetPolicy do
  @moduledoc """
  Explicit selective research policy, separate from historical all-record search.

  A verified passing baseline leaves no quality headroom for this task-local
  search. Running its original task and then another experiment cannot retire
  requests already spent, so this policy abstains before resolving an improver.
  It does not claim efficiency from abstention or qualify persistent reuse.

  A skill trigger is a bounded literal phrase in the public task, never a regex,
  command or authority claim. The host still reviews its complete bytes and
  measures actual loader use. A match establishes applicability for a trial,
  not that the procedure helps.
  """

  @policy %{
    "id" => "selective_assets/v1",
    "admission" => "failed_public_verification_only",
    "skill_trigger" => "bounded_case_insensitive_current_public_evidence_phrase",
    "skill_invocation" => "body_read_before_effectful_tools_one_bounded_continuation",
    "unused_candidate" => "reject_after_first_probe",
    "single_candidate_composition" => "reuse_exact_evaluations"
  }

  @spec policy() :: map()
  def policy, do: @policy

  @spec valid?(policy :: term()) :: boolean()
  def valid?(policy), do: policy == @policy

  @doc "Current public task conversation, excluding system guidance, metadata and private grades."
  @spec trigger_source(record :: map()) :: String.t()
  def trigger_source(record) do
    [
      record["task_request"]
      | Enum.map(~w(original selected), &observation_text(record[&1] || %{}))
    ]
    |> text_values()
    |> Enum.join("\n")
  end

  defp observation_text(observation) do
    # Session/system entries can carry recalled experience. Counting those
    # bytes as this task's evidence would let a stale lesson match itself.
    trajectory =
      for %{"type" => type, "payload" => payload} <- observation["transcript"] || [],
          type in ~w(user assistant tool_result subagent_result subagent_group_result),
          do: payload

    [observation["answer"] | trajectory]
  end

  defp text_values(value) when is_binary(value), do: [value]
  defp text_values(values) when is_list(values), do: Enum.flat_map(values, &text_values/1)

  defp text_values(value) when is_map(value),
    do: value |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(&text_values(elem(&1, 1)))

  defp text_values(_other), do: []

  @spec admission(record :: map()) :: map()
  def admission(%{
        "selected" => %{
          "status" => "completed",
          "provider_error" => nil,
          "usage" => %{"input_tokens" => input, "output_tokens" => output}
        },
        "public_grades" => %{"selected" => %{"passed" => passed, "safety_failures" => []}}
      })
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
             is_boolean(passed),
      do: admission_decision(passed)

  def admission(_record),
    do: %{"decision" => "abstain", "reason" => "source_evidence_unavailable_or_unsafe"}

  defp admission_decision(true),
    do: %{"decision" => "abstain", "reason" => "verified_baseline_has_no_quality_headroom"}

  defp admission_decision(false),
    do: %{"decision" => "search", "reason" => "public_verification_failed"}

  @spec matches?(triggers :: [String.t()], task :: String.t()) :: boolean()
  def matches?(triggers, task) when is_list(triggers) and is_binary(task) do
    task = String.downcase(task)

    Enum.any?(triggers, fn trigger ->
      is_binary(trigger) and String.length(trigger) in 8..160 and
        length(String.split(trigger)) >= 2 and
        String.contains?(task, String.downcase(trigger))
    end)
  end

  def matches?(_triggers, _task), do: false

  @spec probe_count(candidates :: 1 | 2) :: pos_integer()
  def probe_count(1), do: 4
  def probe_count(2), do: 8
end
