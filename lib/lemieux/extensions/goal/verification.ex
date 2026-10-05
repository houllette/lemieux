defmodule Lemieux.Extensions.Goal.Verification do
  @moduledoc """
  Bounded deterministic checks and optional separately billed read-only review.

  `:reviewer` is nil, or a map with `:definition` (a Subagent.Definition),
  `:options` (including a tree `:max_cost_usd`), `:timeout_ms` and `:accept`.
  The definition must also bound requests. `accept.(result)` returns the same
  pass/evidence or fail/reason shape as a deterministic check. Review is attempted
  only after every deterministic criterion passes. Child failure, malformed
  acceptance and snapshot drift never count as completion. The ordinary parent
  delegation ledger retains all reviewer usage, including unsuccessful attempts.
  """
  alias Lemieux.Contract
  alias Lemieux.Session.Document
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Result
  alias Lemieux.Subagent.Task, as: SubagentTask
  alias Lemieux.Supervisor, as: Sup

  @doc false
  @spec validate_reviewer!(reviewer :: term()) :: :ok
  def validate_reviewer!(nil), do: :ok

  def validate_reviewer!(%{
        definition: %Definition{} = definition,
        options: opts,
        timeout_ms: timeout,
        accept: accept
      })
      when is_list(opts) and is_integer(timeout) and timeout in 1..60_000 and
             is_function(accept, 1) do
    Definition.validate!(definition)

    unless is_integer(definition.max_requests) and definition.max_requests > 0 and
             is_number(opts[:max_cost_usd]) and opts[:max_cost_usd] > 0,
           do: raise(ArgumentError, "reviewer requires request and tree cost bounds")

    :ok
  end

  def validate_reviewer!(_invalid), do: raise(ArgumentError, "invalid goal reviewer")

  @doc false
  @spec run(config :: struct(), goal :: map(), context :: map()) :: map()
  def run(config, goal, context) do
    checked =
      bounded(context, config.verify_timeout_ms, fn -> inspect_checks(config, goal, context) end)

    finish(config, goal, context, checked)
  end

  defp inspect_checks(config, goal, context) do
    with {:ok, before} <- snapshot(config, context) do
      input = %{goal: goal, snapshot: before, context: context}
      checks = Enum.map(goal["criteria"], &check(config.checks, &1, input))
      {:checked, before, checks}
    end
  end

  defp check(checks, criterion, input) do
    result =
      case Map.get(checks, criterion) do
        fun when is_function(fun, 1) -> normalize(fun.(input))
        _missing -> unverified("missing criterion check")
      end

    Map.put(result, "criterion", criterion)
  end

  defp finish(config, goal, context, {:checked, before, checks}) do
    review =
      if Enum.all?(checks, &(&1["status"] == "passed")),
        do: review(config.reviewer, config, goal, before, context),
        else: nil

    after_snapshot =
      bounded(context, config.verify_timeout_ms, fn -> snapshot(config, context) end)

    stable = after_snapshot == {:ok, before}

    outcomes =
      if review, do: checks ++ [Map.put(review, "criterion", "independent_review")], else: checks

    status =
      if stable and Enum.all?(outcomes, &(&1["status"] == "passed")),
        do: "passed",
        else: "unverified"

    %{
      "status" => status,
      "snapshot" => before,
      "snapshot_digest" => Contract.digest(before),
      "snapshot_stable" => stable,
      "checks" => outcomes
    }
  end

  defp finish(_config, _goal, _context, _failure),
    do: unverified("verification failed or exceeded its deadline")

  defp snapshot(config, context) do
    case config.snapshot.(context) do
      {:ok, value} when is_map(value) and map_size(value) > 0 ->
        with :ok <- Document.validate("goal.snapshot", value), do: {:ok, value}

      _invalid ->
        {:error, :snapshot_unavailable}
    end
  end

  defp review(nil, _config, _goal, _snapshot, _context), do: nil

  defp review(reviewer, config, goal, snapshot, context) do
    task =
      SubagentTask.new(
        objective: "Independently verify: " <> goal["objective"],
        acceptance_criteria: goal["criteria"],
        snapshot: snapshot,
        non_goals: ["Do not change files or accept the parent's assertion as evidence."]
      )

    opts =
      reviewer.options
      |> Keyword.put(:deadline_ms, reviewer.timeout_ms)
      |> Keyword.put(:progress, assess: false)

    case Subagent.spawn(context.session, reviewer.definition, task, opts) do
      {:ok, ref} ->
        await_review(ref, reviewer, config, context)

      _failure ->
        unverified("independent review unavailable")
    end
  end

  defp await_review(ref, reviewer, config, context) do
    case Subagent.await(ref, reviewer.timeout_ms) do
      {:ok, %Result{status: :ok} = result} ->
        bounded(context, config.verify_timeout_ms, fn -> normalize(reviewer.accept.(result)) end)
        |> review_result(ref.id)

      _failure ->
        Subagent.cancel(ref, :goal_review_incomplete)
        unverified("independent review incomplete")
    end
  end

  defp review_result(%{"status" => _status} = result, id),
    do: Map.put(result, "child_session_id", id)

  defp review_result(_failure, _id), do: unverified("invalid independent review")

  defp bounded(context, timeout, fun) do
    task = Task.Supervisor.async(Sup.task_supervisor(context.supervisor), fn -> safe(fun) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _failure -> :unverified
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _error -> :unverified
  catch
    _kind, _reason -> :unverified
  end

  defp normalize({:pass, refs}) when is_list(refs) and length(refs) in 1..16 do
    if Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..1000)),
      do: %{"status" => "passed", "evidence" => refs},
      else: unverified("invalid evidence")
  end

  defp normalize({:fail, reason}) when is_binary(reason),
    do: %{"status" => "failed", "reason" => String.slice(reason, 0, 1000)}

  defp normalize(_invalid), do: unverified("invalid check response")
  defp unverified(reason), do: %{"status" => "unverified", "reason" => reason}
end
