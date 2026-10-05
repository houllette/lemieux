defmodule Lemieux.Subagent.Acceptance do
  @moduledoc """
  Host-run acceptance checks, separate from child execution and answer format.

  Each criterion needs a host-supplied check returning `{:pass, evidence_refs}`
  or `{:fail, reason}`. Missing, crashing or malformed checks stay unverified.
  Checks run in the caller, never in a session's GenServer; they should inspect
  already collected evidence. Model-backed review belongs in a bounded agent
  session whose usage the host accounts for. A model's own assertion is not a
  passing check. Assessments bind the brief, workspace snapshot and answer.
  The returned envelope can be stored by the host; this operation does not
  rewrite the original child result in the append-only transcript.
  """

  alias Lemieux.Contract
  alias Lemieux.Subagent.Result
  alias Lemieux.Subagent.Task

  @doc "Assesses each named criterion while retaining the full child outcome."
  @spec assess(result :: Result.t(), task :: Task.t(), checks :: map()) :: Result.t()
  def assess(%Result{} = result, %Task{} = task, checks) when is_map(checks) do
    Task.validate!(task)
    outcomes = Enum.map(task.acceptance_criteria, &check(&1, Map.get(checks, &1), result))

    assessment = %{
      "version" => 1,
      "status" => status(result, outcomes),
      "task_digest" => Task.digest(task),
      "result_digest" => Contract.digest(Result.to_map(%{result | acceptance: nil})),
      "snapshot" => task.snapshot,
      "checks" => outcomes
    }

    %{result | acceptance: assessment}
  end

  defp status(%{status: status}, _outcomes) when status != :ok, do: "unverified"
  defp status(_result, []), do: "unverified"

  defp status(_result, outcomes) do
    cond do
      Enum.any?(outcomes, &(&1["status"] == "failed")) -> "failed"
      Enum.all?(outcomes, &(&1["status"] == "passed")) -> "passed"
      true -> "unverified"
    end
  end

  defp check(criterion, fun, result) when is_function(fun, 1) do
    outcome = normalize(fun.(result))
    Map.put(outcome, "criterion", criterion)
  rescue
    _error -> %{"criterion" => criterion, "status" => "unverified", "reason" => "check raised"}
  catch
    _kind, _reason ->
      %{"criterion" => criterion, "status" => "unverified", "reason" => "check exited"}
  end

  defp check(criterion, _missing, _result),
    do: %{"criterion" => criterion, "status" => "unverified", "reason" => "no check supplied"}

  defp normalize({:pass, refs}) when is_list(refs) and refs != [] do
    if Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..1024)),
      do: %{"status" => "passed", "evidence" => refs},
      else: %{"status" => "unverified", "reason" => "invalid evidence references"}
  end

  defp normalize({:fail, reason}) when is_binary(reason),
    do: %{"status" => "failed", "reason" => String.slice(reason, 0, 1024)}

  defp normalize(_invalid), do: %{"status" => "unverified", "reason" => "invalid check result"}
end
