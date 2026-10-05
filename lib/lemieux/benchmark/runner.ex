defmodule Lemieux.Benchmark.Runner do
  @moduledoc false

  alias Lemieux.Benchmark.Artifact
  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Summary
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.Workspace

  @spec run(Manifest.t(), [Runtime.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Manifest{} = manifest, runtimes, opts)
      when is_list(runtimes) and runtimes != [] and is_list(opts) do
    with :ok <- validate_runtimes(runtimes),
         {:ok, repetitions} <- repetitions(opts),
         {:ok, max_concurrency} <- max_concurrency(opts),
         :ok <- validate_progress(opts),
         :ok <- validate_retry(opts),
         :ok <- validate_budget(opts) do
      {results, execution} =
        attempts(manifest.tasks, runtimes, repetitions, max_concurrency, opts)

      names = Enum.map(runtimes, & &1.name)

      report = %{
        "schema_version" => 1,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "manifest" => %{
          "metadata" => manifest.metadata,
          "tasks" => Enum.map(manifest.tasks, &task/1)
        },
        "results" => results,
        "execution" => execution,
        "summary" => Summary.build(results, names)
      }

      with :ok <- maybe_write(opts[:output], report), do: {:ok, report}
    end
  end

  def run(%Manifest{}, [], _opts), do: {:error, :no_runtimes}

  defp attempts(tasks, runtimes, repetitions, max_concurrency, opts) do
    specs =
      tasks
      |> Enum.with_index()
      |> Enum.flat_map(fn {task, task_index} ->
        Enum.flat_map(1..repetitions, fn repetition ->
          runtimes
          |> rotate(task_index + repetition - 1)
          |> Enum.map(&{task, &1, repetition})
        end)
      end)

    cap = Keyword.get(opts, :cost_cap_usd)

    reservation = Keyword.get(opts, :max_cost_per_attempt_usd)
    budget = %{cap: cap, reservation: reservation}
    state = %{results: [], actual: 0.0, reserved: 0.0, unknown: 0}

    outcome = run_specs(specs, max_concurrency, opts, budget, state)

    cap_reached? = outcome.remaining > 0 and is_number(cap) and outcome.actual >= cap
    reservation_blocked? = outcome.remaining > 0 and outcome.reason == "cost_reservation"
    aborted = cap_reached? or reservation_blocked?

    execution = %{
      "max_concurrency" => max_concurrency,
      "scheduled" => length(outcome.results),
      "planned" => length(specs),
      "aborted" => aborted,
      "reason" => if(aborted, do: outcome.reason || "cost_cap", else: nil),
      "actual_cost_usd" => outcome.actual,
      "unknown_cost_runs" => outcome.unknown,
      "reserved_cost_usd" => outcome.reserved,
      "released_cost_usd" => max(outcome.reserved - outcome.actual, 0.0)
    }

    {outcome.results, execution}
  end

  defp run_specs([], _concurrency, _opts, _budget, state),
    do: Map.merge(state, %{remaining: 0, reason: nil})

  defp run_specs(specs, concurrency, opts, %{cap: nil} = budget, state) do
    # Without a cost cap, async_stream can refill each free slot immediately.
    # Fixed batches left completed workers idle behind their slowest peer.
    # Capped runs below still reserve a whole batch before starting it.
    results = run_batch(specs, concurrency, opts)

    state
    |> append_results(results, budget.reservation)
    |> Map.merge(%{remaining: 0, reason: nil})
  end

  defp run_specs(specs, concurrency, opts, budget, state) do
    batch_size =
      reservable_count(specs, concurrency, budget.cap, budget.reservation, state.actual)

    cond do
      batch_size == 0 ->
        reason = if is_number(budget.reservation), do: "cost_reservation", else: "cost_cap"
        Map.merge(state, %{remaining: length(specs), reason: reason})

      is_number(budget.cap) and state.actual >= budget.cap ->
        Map.merge(state, %{remaining: length(specs), reason: "cost_cap"})

      true ->
        {batch, rest} = Enum.split(specs, batch_size)
        batch_results = run_batch(batch, concurrency, opts)
        next = append_results(state, batch_results, budget.reservation)
        run_specs(rest, concurrency, opts, budget, next)
    end
  end

  defp append_results(state, results, reservation) do
    {actual, unknown} = accounted_cost(results, reservation)
    reserved = if is_number(reservation), do: reservation * length(results), else: 0.0

    %{
      results: state.results ++ results,
      actual: state.actual + actual,
      reserved: state.reserved + reserved,
      unknown: state.unknown + unknown
    }
  end

  defp reservable_count(specs, concurrency, cap, reservation, actual)
       when is_number(cap) and is_number(reservation) do
    available = max(cap - actual, 0.0)
    affordable = floor(available / reservation)
    min(length(specs), min(concurrency, affordable))
  end

  defp reservable_count(specs, concurrency, _cap, _reservation, _actual),
    do: min(length(specs), concurrency)

  defp run_batch(batch, 1, opts) do
    Enum.map(batch, fn {task, runtime, repetition} -> attempt(task, runtime, repetition, opts) end)
  end

  defp run_batch(batch, max_concurrency, opts) do
    batch
    |> Elixir.Task.async_stream(
      fn {task, runtime, repetition} -> attempt(task, runtime, repetition, opts) end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # A discarded retry is paid work. Charging only the retained attempt would
  # have let a cost cap authorize twice what it meant to.
  defp accounted_cost(results, reservation) do
    results
    |> Enum.flat_map(fn result ->
      [get_in(result, ["observation", "usage", "cost_usd"])] ++
        Enum.map(result["retries"] || [], & &1["cost_usd"])
    end)
    |> Enum.reduce({0.0, 0}, fn
      measured, {cost, unknown} when is_number(measured) -> {cost + measured, unknown}
      _unknown, {cost, unknown} when is_number(reservation) -> {cost + reservation, unknown + 1}
      _unknown, {cost, unknown} -> {cost, unknown + 1}
    end)
  end

  # Deterministic rotation rather than random shuffling: provider conditions
  # and a warming filesystem do not always favour the same runtime, while an
  # artifact remains reproducible enough to inspect by eye.
  defp rotate(runtimes, offset) do
    {front, back} = Enum.split(runtimes, rem(offset, length(runtimes)))
    back ++ front
  end

  defp attempt(task, runtime, attempt, opts) do
    id = {task.id, runtime.name, attempt}
    started = System.monotonic_time(:millisecond)

    notify_progress(opts, %{
      event: :attempt_started,
      id: id,
      task_id: task.id,
      runtime: runtime.name,
      attempt: attempt,
      timeout_ms: task.timeout_ms
    })

    result = run_attempt(task, runtime, attempt, opts)

    notify_progress(opts, %{
      event: :attempt_finished,
      id: id,
      task_id: task.id,
      runtime: runtime.name,
      attempt: attempt,
      passed: result["passed"],
      error: result["error"],
      finish_reason: get_in(result, ["observation", "finish_reason"]),
      requests: get_in(result, ["observation", "resources", "requests"]),
      retries: length(result["retries"] || []),
      wall_time_ms: System.monotonic_time(:millisecond) - started
    })

    result
  end

  # A stream that stalls mid-answer says nothing about the runtime under test; it
  # says the connection died. Retrying that is not a second sample of the same
  # question, so the retained result keeps the attempt's own number and the
  # discarded try is recorded beside it. The caller owns the predicate — the runner
  # has no opinion about which failures are the apparatus.
  defp run_attempt(task, runtime, attempt, opts) do
    result = execute_attempt(task, runtime, attempt, opts)
    retry(result, task, runtime, attempt, opts, Keyword.get(opts, :retry), [])
  end

  defp retry(result, _task, _runtime, _attempt, _opts, nil, _discarded), do: result

  defp retry(result, task, runtime, attempt, opts, retry, discarded) do
    if length(discarded) < Keyword.fetch!(retry, :max) and decided?(retry, result) do
      next = execute_attempt(task, runtime, attempt, opts)
      retry(next, task, runtime, attempt, opts, retry, discarded ++ [discarded(result)])
    else
      retained(result, discarded)
    end
  end

  # A predicate that raises is not a reason to lose the attempt that provoked
  # it; the result stands and no retry is spent.
  defp decided?(retry, result) do
    retry |> Keyword.fetch!(:when) |> then(& &1.(result)) == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp retained(result, []), do: result
  defp retained(result, discarded), do: Map.put(result, "retries", discarded)

  # Bounded on purpose: enough to say what failed and what it cost, never the
  # discarded transcript. The retained attempt's transcript is the evidence.
  defp discarded(result) do
    %{
      "discarded" => true,
      "passed" => result["passed"],
      "error" => result["error"],
      "wall_time_ms" => result["wall_time_ms"],
      "finish_reason" => get_in(result, ["observation", "finish_reason"]),
      "provider_error" => get_in(result, ["observation", "provider_error"]),
      "session_id" => get_in(result, ["observation", "session_id"]),
      "cost_usd" => get_in(result, ["observation", "usage", "cost_usd"]),
      "resources" => get_in(result, ["observation", "resources"])
    }
  end

  defp execute_attempt(task, runtime, attempt, opts) do
    context = %{
      attempt: attempt,
      runtime: runtime.name,
      workspace_root: Keyword.get(opts, :workspace_root)
    }

    case prepare(task, context, opts) do
      {:ok, prepared, cleanup} ->
        try do
          execute(prepared, runtime, attempt)
        after
          cleanup.()
        end

      {:error, reason} ->
        failed(task, runtime, attempt, {:workspace, reason})
    end
  end

  defp prepare(task, context, opts) do
    case Keyword.get(opts, :workspace, :copy) do
      :copy -> Workspace.copy(task, context)
      :in_place -> Workspace.in_place(task, context)
      fun when is_function(fun, 2) -> fun.(task, context)
    end
  end

  defp execute(task, runtime, attempt) do
    started = System.monotonic_time(:millisecond)
    outcome = safely(fn -> Runtime.run(runtime, task) end)
    wall = System.monotonic_time(:millisecond) - started

    case outcome do
      {:error, reason, observation} when is_map(observation) ->
        failed(task, runtime, attempt, reason, wall, observation)

      {:ok, observation} when is_map(observation) ->
        grade(task, runtime, attempt, observation, wall)

      {:error, reason} ->
        failed(task, runtime, attempt, reason, wall)
    end
  end

  defp grade(task, runtime, attempt, observation, wall) do
    answer = Map.get(observation, "answer", "")

    case safely(fn -> CommandGrader.grade(task.grader, task, answer) end) do
      {:ok, grader} ->
        %{
          "task_id" => task.id,
          "runtime" => runtime.name,
          "attempt" => attempt,
          "passed" => grader["passed"],
          "wall_time_ms" => wall,
          "observation" => observation,
          "grader" => grader,
          "error" => nil
        }

      {:error, reason} ->
        failed(task, runtime, attempt, {:grader, reason}, wall, observation)
    end
  end

  defp failed(task, runtime, attempt, reason, wall \\ 0, observation \\ nil) do
    %{
      "task_id" => task.id,
      "runtime" => runtime.name,
      "attempt" => attempt,
      "passed" => false,
      "wall_time_ms" => wall,
      "observation" => observation,
      "grader" => nil,
      "error" => inspect(reason)
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:raised, Exception.format(:error, error, __STACKTRACE__)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_runtimes(runtimes) do
    if Enum.all?(runtimes, &match?(%Runtime{}, &1)) and unique_names?(runtimes),
      do: :ok,
      else: {:error, :invalid_runtimes}
  end

  defp unique_names?(runtimes) do
    names = Enum.map(runtimes, & &1.name)
    length(names) == MapSet.size(MapSet.new(names))
  end

  defp repetitions(opts) do
    case Keyword.get(opts, :repetitions, 1) do
      repetitions when is_integer(repetitions) and repetitions > 0 -> {:ok, repetitions}
      _invalid -> {:error, :invalid_repetitions}
    end
  end

  defp max_concurrency(opts) do
    case Keyword.get(opts, :max_concurrency, 1) do
      concurrency when is_integer(concurrency) and concurrency > 0 -> {:ok, concurrency}
      _invalid -> {:error, :invalid_max_concurrency}
    end
  end

  # `retry: [max: n, when: fun]`, or nothing. Validated before anything runs
  # rather than discovered on the first failed attempt, when a bad predicate
  # would already have cost a provider call.
  defp validate_retry(opts) do
    case Keyword.get(opts, :retry) do
      nil ->
        :ok

      retry when is_list(retry) ->
        max = Keyword.get(retry, :max)
        decide = Keyword.get(retry, :when)

        if is_integer(max) and max > 0 and is_function(decide, 1),
          do: :ok,
          else: {:error, :invalid_retry}

      _invalid ->
        {:error, :invalid_retry}
    end
  end

  defp validate_progress(opts) do
    case Keyword.get(opts, :progress) do
      nil -> :ok
      pid when is_pid(pid) -> :ok
      callback when is_function(callback, 1) -> :ok
      _invalid -> {:error, :invalid_progress_reporter}
    end
  end

  defp notify_progress(opts, event) do
    case Keyword.get(opts, :progress) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        send(pid, {:benchmark_progress, event})
        :ok

      callback when is_function(callback, 1) ->
        try do
          callback.(event)
        rescue
          _error -> :ok
        catch
          _kind, _reason -> :ok
        end
    end
  end

  defp validate_budget(opts) do
    estimate = Keyword.get(opts, :estimated_cost_usd)
    cap = Keyword.get(opts, :cost_cap_usd)
    reservation = Keyword.get(opts, :max_cost_per_attempt_usd)

    with :ok <- positive_option(cap, :invalid_cost_cap),
         :ok <- nonnegative_option(estimate, :invalid_estimated_cost),
         :ok <- positive_option(reservation, :invalid_attempt_cost_reservation) do
      estimate_within_cap(estimate, cap)
    end
  end

  defp positive_option(nil, _error), do: :ok
  defp positive_option(value, _error) when is_number(value) and value > 0, do: :ok
  defp positive_option(_value, error), do: {:error, error}

  defp nonnegative_option(nil, _error), do: :ok
  defp nonnegative_option(value, _error) when is_number(value) and value >= 0, do: :ok
  defp nonnegative_option(_value, error), do: {:error, error}

  defp estimate_within_cap(estimate, cap)
       when is_number(estimate) and is_number(cap) and estimate > cap,
       do: {:error, {:estimated_cost_exceeds_cap, estimate, cap}}

  defp estimate_within_cap(_estimate, _cap), do: :ok

  defp task(%Task{} = task) do
    %{
      "id" => task.id,
      "prompt" => task.prompt,
      "metadata" => task.metadata,
      "timeout_ms" => task.timeout_ms
    }
  end

  defp maybe_write(nil, _report), do: :ok
  defp maybe_write(path, report), do: Artifact.write(path, report)
end
