defmodule Lemieux.Learning.Refinement.Support do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Frozen task-local selection rules. The default requires separated observations.

  `experimental_mean/v1` compares repeated mean public scores. A perfect control
  observation therefore does not make adoption impossible. This is a search
  heuristic, not a significance test or evidence of transfer. Its receipts need
  separate host permission for experimental task-local execution and cannot
  authorize persistent canaries. Known task failures are outcomes; unsafe or
  incomplete probes disqualify the entire comparison, including unsafe controls.

  Version 2 additionally permits a source-backed candidate on a repeated,
  verified perfect tie. Trying a behaviorally different passing harness is a
  search decision, not evidence it improves quality. Requiring a score increase
  even to try such a candidate prevented the improver from operating on solved
  tasks. Efficacy still requires separately registered held-out comparisons.
  """
  alias Lemieux.Learning.Refinement.Evidence

  @spec strict() :: map()
  def strict, do: %{"id" => "strict/v1"}

  @spec verify(policy :: term()) :: :ok | {:error, term()}
  def verify(%{"id" => "strict/v1"} = policy) when map_size(policy) == 1, do: :ok

  def verify(
        %{
          "id" => "experimental_mean/v1",
          "minimum_gain" => gain,
          "minimum_repetitions" => repetitions
        } = policy
      )
      when map_size(policy) == 3 and is_number(gain) and gain > 0 and gain <= 1 and
             repetitions in 2..5,
      do: :ok

  def verify(%{"id" => "experimental_mean/v2", "verified_ties" => true} = policy)
      when map_size(policy) == 4 do
    policy |> Map.delete("verified_ties") |> Map.put("id", "experimental_mean/v1") |> verify()
  end

  def verify(_policy), do: {:error, :invalid_support_policy}

  @spec experimental?(policy :: term()) :: boolean()
  def experimental?(%{"id" => id} = policy),
    do: id in ~w(experimental_mean/v1 experimental_mean/v2) and verify(policy) == :ok

  def experimental?(_policy), do: false

  @spec supported?(
          control :: list(),
          candidate :: list(),
          verifier? :: boolean(),
          policy :: map()
        ) :: boolean()
  def supported?(control, candidate, verifier?, %{"id" => "strict/v1"} = policy),
    do: verify(policy) == :ok and Evidence.supported?(control, candidate, verifier?)

  def supported?(control, candidate, verifier?, policy) do
    verify(policy) == :ok and is_list(control) and is_list(candidate) and
      length(control) == length(candidate) and length(control) >= policy["minimum_repetitions"] and
      Enum.all?(control ++ candidate, &complete?(&1, verifier?)) and
      admissible_performance?(control, candidate, verifier?, policy)
  end

  defp admissible_performance?(control, candidate, verifier?, policy) do
    mean(candidate) - mean(control) >= policy["minimum_gain"] or
      (policy["verified_ties"] == true and verifier? and
         Enum.all?(control ++ candidate, &(&1["score"] == 1 and &1["verified_success"] == true)))
  end

  defp complete?(record, verifier?) do
    score = record["score"]

    is_number(score) and score >= 0 and score <= 1 and
      record["evidence_complete"] == true and record["safety_failure"] == false and
      (not verifier? or is_boolean(record["verified_success"]))
  end

  defp mean(records), do: Enum.sum(Enum.map(records, & &1["score"])) / length(records)
end
