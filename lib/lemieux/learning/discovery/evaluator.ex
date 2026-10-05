defmodule Lemieux.Learning.Discovery.Evaluator do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Turns benchmark reports into discovery evaluations, and runs one candidate
  to produce them.

  Until this module existed the shadow loop could only be driven by inline
  test functions: `Lemieux.Benchmark` produced attempt results and
  `Lemieux.Learning.Discovery.Evaluation` demanded a digest-verified
  observation, and nothing converted one into the other. The conversion is
  pure and lives in `from_report/4`; `run/3` composes the benchmark runner
  with it for a live or scripted candidate.

  Three mappings carry the honesty of the whole search and are therefore
  fixed here rather than left to each caller:

    * **Objectives come from the plan, by name.** Every plan objective must
      map to a fact the report actually contains; an objective the report
      cannot supply is an error, never a zero. A quota provider reports no
      dollars, so a plan on such a provider must not declare `cost_usd` as an
      objective.
    * **Safety is mechanical.** A case's `metadata.safety.allowed_changed_paths`
      is the allowlist; any changed path outside it is a safety failure. A
      runtime that cannot attest writes outside the workspace leaves sandbox
      completeness `"unknown"` unless the plan's hard constraints declare the
      local trusted lane (`sandbox: :not_applicable`), which excludes such
      candidates from the frontier by construction.
    * **Cost completeness follows the plan's budget mode.** Under
      `unknown_cost: "allow"` an unpriced run records cost as
      `"not_applicable"` so a quota campaign can produce eligible evidence;
      otherwise unknown cost stays `"unknown"` and the evaluation is ineligible.
    * **A limit the profile owns is the candidate's failure, not missing
      evidence.** An attempt that stops at the profile's `max_turns`,
      request, token or cost bound, or at the harness's no-progress stop,
      is terminal and within budget with `task_success` 0. The evaluator's
      wall-clock timeouts and a provider stream that stalled mid-answer
      leave an attempt outside budget and therefore ineligible.
    * **A provider stream timeout is the apparatus, not the candidate.** It is
      retried once by default, the discarded try is retained in the
      evaluation's observations as `"retries"`, and the attempt keeps its own
      number: a retry is never a second sample. If the retry stalls too, the
      attempt is recorded outside budget rather than as a wrong answer,
      because a stream that never delivered measured nothing. Pass
      `retry_provider_timeouts: false` to record the first failure instead, or
      supply a `:retry` inside `:benchmark` to decide differently.

  Transcripts are retained as content-addressed artifacts and returned beside
  the evaluations so a digester can read them without a second store.
  """

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Gate
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Agent, as: AgentRuntime
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan

  # Only the evaluator's own clocks put an attempt outside budget. A stop at
  # `:max_turns`, `:budget` or `:no_progress` is the profile under test hitting the
  # bounds it declares for itself, which is hard evidence of a terminal failure.
  # The first two-model cycle treated those as missing evidence and lost every
  # candidate, seed included, because one model ran one case to its turn limit — a
  # rule that empties the frontier whenever one model loops once cannot rank
  # anything.
  @evaluator_stops [":benchmark_timeout", ":agent_timeout"]
  # The one provider failure that is also not the candidate's. The verifier
  # comparison lost most of its plain-arm attempts to stalled streams, which
  # the report could not tell from wrong answers; ranking a candidate on a
  # connection that died is ranking the network.
  @provider_stop ":error"

  @typedoc "Retained artifact bytes keyed by SHA-256."
  @type artifacts :: %{String.t() => binary()}

  @typedoc """
  Evaluations built from a report, the transcript bytes they reference, and
  the attempts that produced no observation at all. An attempt whose runtime
  crashed before the agent ran is not evidence about the candidate, so it is
  reported beside the evaluations rather than encoded as one with invented
  objective values.
  """
  @type result :: %{
          evaluations: [Evaluation.t()],
          artifacts: artifacts(),
          incomplete: [map()]
        }

  @doc """
  Maps one benchmark report to evaluations for `candidate`.

  Options:

    * `:runtime` — the report runtime name to read (default `candidate.id`).
    * `:allowed_changed_paths` — `%{case_id => [path]}`; missing case → no
      allowlist check for that case.
    * `:sandbox` — `:required` (default) or `:not_applicable`.
    * `:unknown_cost` — `"reject"` (default) or `"allow"`; normally read from
      `plan.budget["unknown_cost"]`.
  """
  @spec from_report(
          plan :: Plan.t(),
          candidate :: Candidate.t(),
          report :: map(),
          opts :: keyword()
        ) :: {:ok, result()} | {:error, term()}
  def from_report(%Plan{} = plan, %Candidate{} = candidate, report, opts \\ [])
      when is_map(report) and is_list(opts) do
    runtime = Keyword.get(opts, :runtime, candidate.id)
    results = report |> Map.get("results", []) |> Enum.filter(&(&1["runtime"] == runtime))
    empty = %{evaluations: [], artifacts: %{}, incomplete: []}

    Enum.reduce_while(results, {:ok, empty}, fn result, {:ok, acc} ->
      if is_map(result["observation"]) do
        collect(plan, candidate, result, opts, acc)
      else
        {:cont, {:ok, %{acc | incomplete: acc.incomplete ++ [incomplete(result)]}}}
      end
    end)
  end

  defp collect(plan, candidate, result, opts, acc) do
    case evaluation(plan, candidate, result, opts) do
      {:ok, evaluation, more} ->
        {:cont,
         {:ok,
          %{
            acc
            | evaluations: acc.evaluations ++ [evaluation],
              artifacts: Map.merge(acc.artifacts, more)
          }}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp incomplete(result) do
    %{
      "case_id" => result["task_id"],
      "attempt" => result["attempt"],
      "error" => result["error"],
      "wall_time_ms" => result["wall_time_ms"]
    }
  end

  @doc """
  Runs `candidate` on the selected cases and returns its evaluations.

  The candidate content is a session profile (`Lemieux.Extension.Profile`
  shape). Required options: `:manifest`, `:profile` (decoded content) and
  `:provider`. Optional: `:case_ids` (default every plan case present in the
  manifest), `:tool_registry`, `:session` (extra session options such as
  hooks or an environment), `:benchmark` (runner options such as workspace,
  concurrency, cost caps), `:sessions_dir`, plus the `from_report/4` options.

  `:attempts` (`%{case_id => count}`, or a list of such pairs) repeats a case
  that many times, each attempt its own session and its own evaluation with
  ids `eval_<candidate>_<case>_1`, `_2`, and so on. A case it does not name
  runs `:benchmark`'s `:repetitions` (default 1) times, and a count that is
  not a positive integer is refused before anything runs.

  `:models` evaluates every case on each listed model and merges the results
  into one evaluation per case: every objective becomes the mean across
  models, safety passes only if it passed on all of them, and the per-model
  values are kept in the evaluation's observations. A plan may also declare
  `name@model` objectives to keep one model's value visible to the frontier.
  Each entry is a model string or a map with `"model"` plus
  `Lemieux.Extension.Profile.retarget/3` options as `"usage_mode"`,
  `"max_cost_usd"` and `"max_requests"`. The candidate's own model is used
  when `:models` is absent. The point is the user's, not a vendor's: an edit
  is only as good as its worst model, so a portfolio keeps the search from
  quietly optimizing for one.
  """
  @spec run(plan :: Plan.t(), candidate :: Candidate.t(), opts :: keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(%Plan{} = plan, %Candidate{} = candidate, opts) when is_list(opts) do
    with {:ok, manifest} <- fetch(opts, :manifest),
         {:ok, profile} <- fetch(opts, :profile),
         {:ok, provider} <- fetch(opts, :provider),
         {:ok, tasks} <- select_tasks(plan, manifest, Keyword.get(opts, :case_ids)),
         {:ok, attempts} <- attempt_counts(tasks, Keyword.get(opts, :attempts, %{}), opts),
         {:ok, targets} <- targets(profile, Keyword.get(opts, :models)) do
      report_opts =
        opts
        |> Keyword.take([:sandbox, :unknown_cost])
        |> Keyword.put_new(:unknown_cost, plan.budget["unknown_cost"] || "reject")
        |> Keyword.put(:allowed_changed_paths, allowlists(tasks))

      run = %{
        plan: plan,
        candidate: candidate,
        tasks: tasks,
        attempts: attempts,
        manifest: manifest,
        provider: provider,
        opts: opts,
        report_opts: report_opts
      }

      case run_targets(run, targets) do
        {:ok, [{_model, single}]} -> {:ok, single}
        {:ok, results} -> merge_models(plan, candidate, results)
        error -> error
      end
    end
  end

  # One benchmark run per target model, in the order the targets were listed;
  # the first failure stops the rest.
  defp run_targets(run, targets) do
    Enum.reduce_while(targets, {:ok, []}, fn {model, target_profile}, {:ok, results} ->
      case run_target(run, target_profile, model) do
        {:ok, result} -> {:cont, {:ok, results ++ [{model, result}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # `run` bundles what every target shares: the plan and candidate under
  # evaluation, the selected tasks and manifest, the provider, the caller's
  # options and the `from_report/4` options derived from them.
  defp run_target(
         %{plan: plan, candidate: candidate, provider: provider, opts: opts} = run,
         profile,
         model
       ) do
    with {:ok, _agent_options, _profile} <- configure(profile, resolve(provider), opts) do
      # A zero-arity provider factory is resolved once per attempt, so a
      # scripted double gets a fresh script for every session while a real
      # provider is simply reused.
      runtime =
        Runtime.new(candidate.id <> "@" <> model, AgentRuntime,
          agent: Lemieux.Agent.Session,
          agent_options: fn ->
            {:ok, agent_options, _profile} = configure(profile, resolve(provider), opts)
            agent_options
          end
        )

      case run_groups(run, runtime) do
        {:ok, results} ->
          from_report(
            plan,
            candidate,
            %{"results" => results},
            Keyword.put(run.report_opts, :runtime, runtime.name)
          )

        {:error, reason} ->
          {:error, {:benchmark, model, reason}}
      end
    end
  end

  # The runner repeats every task in a manifest the same number of times, so cases
  # with different attempt counts run as separate benchmarks — one per distinct
  # count — and their results merge back in the order the cases were requested.
  # Only the merged results reach `from_report/4`; an `:output` path receives each
  # group's own report in turn.
  defp run_groups(run, runtime) do
    %Manifest{} = manifest = run.manifest
    benchmark = Keyword.get(run.opts, :benchmark, [])
    order = run.tasks |> Enum.with_index() |> Map.new(fn {task, index} -> {task.id, index} end)

    run.tasks
    |> Enum.group_by(&Map.fetch!(run.attempts, &1.id))
    |> Enum.sort_by(fn {count, _tasks} -> count end)
    |> Enum.reduce_while({:ok, []}, fn {count, tasks}, {:ok, results} ->
      options =
        run.opts
        |> retry_options()
        |> Keyword.merge(benchmark)
        |> Keyword.put(:repetitions, count)

      case Benchmark.run(%Manifest{manifest | tasks: tasks}, [runtime], options) do
        {:ok, report} -> {:cont, {:ok, results ++ Map.get(report, "results", [])}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} ->
        {:ok, Enum.sort_by(results, &{Map.fetch!(order, &1["task_id"]), &1["attempt"]})}

      error ->
        error
    end
  end

  # A `:retry` supplied inside `:benchmark` wins: a caller that has decided
  # for itself which failures are the apparatus is not overridden here.
  defp retry_options(opts) do
    if Keyword.get(opts, :retry_provider_timeouts, true),
      do: [retry: [max: 1, when: &provider_stream_timeout?/1]],
      else: []
  end

  @doc """
  Whether one benchmark result is a run that ended on a stalled provider
  stream rather than on anything the candidate did.

  Public because it is the predicate the lane hands the runner, and a host
  comparing arms outside the discovery lane needs the same rule to read a
  retained report the same way. A provider error earlier in a run that then
  finished normally is not one of these: only the stop that ended the run
  counts.
  """
  @spec provider_stream_timeout?(result :: map()) :: boolean()
  def provider_stream_timeout?(result) when is_map(result) do
    observation = result["observation"] || %{}

    observation["finish_reason"] == @provider_stop and
      get_in(observation, ["provider_error", "category"]) == "timeout"
  end

  def provider_stream_timeout?(_result), do: false

  # Attempt counts are settled before anything runs. A case the request
  # names must carry a positive integer; a case it does not name runs the
  # benchmark's own `:repetitions`, which the runner validates itself.
  defp attempt_counts(tasks, requested, opts) when is_map(requested) or is_list(requested) do
    requested = Map.new(requested)
    default = opts |> Keyword.get(:benchmark, []) |> Keyword.get(:repetitions, 1)

    Enum.reduce_while(tasks, {:ok, %{}}, fn task, {:ok, counts} ->
      case Map.fetch(requested, task.id) do
        {:ok, count} when is_integer(count) and count > 0 ->
          {:cont, {:ok, Map.put(counts, task.id, count)}}

        {:ok, _invalid} ->
          {:halt, {:error, {:invalid_attempts, task.id}}}

        :error ->
          {:cont, {:ok, Map.put(counts, task.id, default)}}
      end
    end)
  end

  defp attempt_counts(_tasks, _requested, _opts), do: {:error, :invalid_attempts}

  # The candidate's own model when nothing else is asked; otherwise each
  # listed model, with the budget shape normalized through the one shared
  # retargeting function so the confirmation lane and this evaluator agree.
  defp targets(profile, nil), do: {:ok, [{profile["model"], profile}]}

  defp targets(profile, models) when is_list(models) and models != [] do
    Enum.reduce_while(models, {:ok, []}, fn entry, {:ok, acc} ->
      case target(profile, entry) do
        {:ok, model, retargeted} -> {:cont, {:ok, acc ++ [{model, retargeted}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp targets(_profile, _models), do: {:error, :invalid_models}

  defp target(profile, model) when is_binary(model) and model != "" do
    {retargeted, _changes} = Profile.retarget(profile, model)
    {:ok, model, retargeted}
  end

  defp target(profile, %{"model" => model} = entry) when is_binary(model) and model != "" do
    retarget_opts =
      [
        usage_mode: entry["usage_mode"],
        max_cost_usd: entry["max_cost_usd"],
        max_requests: entry["max_requests"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    {retargeted, _changes} = Profile.retarget(profile, model, retarget_opts)

    case Profile.validate(retargeted) do
      :ok -> {:ok, model, retargeted}
      {:error, reason} -> {:error, {:invalid_model_target, model, reason}}
    end
  end

  defp target(_profile, entry), do: {:error, {:invalid_model_target, entry}}

  # One evaluation per case and attempt out of several per-model ones: means for
  # objectives, all-of for safety, worst-of for completeness, sums for usage and
  # latency, every transcript retained. Attempts merge separately, so a repeated
  # case keeps one observation per attempt across the portfolio as it does on one
  # model.
  defp merge_models(plan, candidate, results) do
    per_attempt =
      results
      |> Enum.flat_map(fn {model, %{evaluations: evaluations}} ->
        Enum.map(evaluations, &{{&1.case_id, attempt(&1)}, model, &1})
      end)
      |> Enum.group_by(fn {key, _model, _evaluation} -> key end)

    artifacts =
      Enum.reduce(results, %{}, fn {_model, result}, acc -> Map.merge(acc, result.artifacts) end)

    incomplete =
      Enum.flat_map(results, fn {model, result} ->
        Enum.map(result.incomplete, &Map.put(&1, "model", model))
      end)

    per_attempt
    |> Enum.sort_by(fn {key, _rows} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {{case_id, attempt}, rows}, {:ok, built} ->
      case merged_evaluation(plan, candidate, case_id, attempt, rows) do
        {:ok, evaluation} -> {:cont, {:ok, built ++ [evaluation]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, evaluations} ->
        {:ok, %{evaluations: evaluations, artifacts: artifacts, incomplete: incomplete}}

      error ->
        error
    end
  end

  defp merged_evaluation(plan, candidate, case_id, attempt, rows) do
    models = Enum.map(rows, fn {_key, model, _evaluation} -> model end)
    evaluations = Enum.map(rows, fn {_key, _model, evaluation} -> evaluation end)
    by_model = Map.new(rows, fn {_key, model, evaluation} -> {model, evaluation} end)

    objectives =
      Map.new(plan.objectives, fn %{"name" => name} ->
        {name, merged_objective(name, by_model, evaluations)}
      end)

    with :ok <- objectives_known(objectives) do
      first = hd(evaluations)

      attrs = %{
        "id" => "eval_#{candidate.id}_#{case_id}_#{attempt}",
        "scope" => plan.scope,
        "case_id" => case_id,
        "split" => first.split,
        "objectives" => objectives,
        "safety" => %{
          "passed" => Enum.all?(evaluations, & &1.safety["passed"]),
          "failures" =>
            Enum.flat_map(rows, fn {_key, model, evaluation} ->
              Enum.map(evaluation.safety["failures"], &"#{model}:#{&1}")
            end)
        },
        "completeness" => merged_completeness(evaluations),
        "usage" => merged_usage(evaluations),
        "cost" => %{"usd" => merged_cost(evaluations)},
        "latency" => %{
          "milliseconds" => Enum.sum(Enum.map(evaluations, &(&1.latency["milliseconds"] || 0)))
        },
        "artifacts" =>
          Enum.flat_map(evaluations, fn evaluation ->
            Enum.map(evaluation.artifacts, &ArtifactReference.to_map/1)
          end),
        "within_budget" => Enum.all?(evaluations, & &1.within_budget),
        "terminal" => Enum.all?(evaluations, & &1.terminal),
        "observations" => %{
          "attempt" => attempt,
          "models" => models,
          "per_model" =>
            Map.new(by_model, fn {model, evaluation} ->
              {model, Map.put(evaluation.observations, "objectives", evaluation.objectives)}
            end)
        }
      }

      Evaluation.new(plan, candidate, attrs)
    end
  end

  # `name@model` names one model's value; a bare name is the mean across
  # models. A per-model objective for a model that was not evaluated is an
  # error, never a zero.
  defp merged_objective(name, by_model, evaluations) do
    case String.split(name, "@", parts: 2) do
      [base, model] ->
        case Map.fetch(by_model, model) do
          {:ok, evaluation} ->
            Map.get(evaluation.objectives, base, Map.get(evaluation.objectives, name))

          :error ->
            :missing_model
        end

      [_base] ->
        values = Enum.map(evaluations, &Map.get(&1.objectives, name))

        if Enum.all?(values, &is_number/1),
          do: Enum.sum(values) / length(values),
          else: :missing_value
    end
  end

  defp objectives_known(objectives) do
    case Enum.find(objectives, fn {_name, value} -> not is_number(value) end) do
      nil -> :ok
      {name, reason} -> {:error, {:objective_unknown, name, reason}}
    end
  end

  @completeness_rank %{"complete" => 0, "not_applicable" => 1, "partial" => 2, "unknown" => 3}

  defp merged_completeness(evaluations) do
    evaluations
    |> Enum.flat_map(& &1.completeness)
    |> Enum.group_by(fn {key, _state} -> key end, fn {_key, state} -> state end)
    |> Map.new(fn {key, states} ->
      {key, Enum.max_by(states, &Map.get(@completeness_rank, &1, 3))}
    end)
  end

  defp merged_usage(evaluations) do
    keys =
      ~w(requests input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens)

    Map.new(keys, fn key ->
      values = Enum.map(evaluations, &Map.get(&1.usage, key))
      {key, if(Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil)}
    end)
  end

  defp merged_cost(evaluations) do
    values = Enum.map(evaluations, & &1.cost["usd"])
    if Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil
  end

  defp attempt(%Evaluation{observations: %{"attempt" => attempt}}) when is_integer(attempt),
    do: attempt

  defp attempt(%Evaluation{}), do: 1

  @doc "Returns the per-case changed-path allowlists declared in a manifest."
  @spec allowlists(tasks :: [Lemieux.Benchmark.Task.t()]) :: %{String.t() => [String.t()]}
  def allowlists(tasks) when is_list(tasks) do
    tasks
    |> Enum.flat_map(fn task ->
      case get_in(task.metadata, ["safety", "allowed_changed_paths"]) do
        paths when is_list(paths) -> [{task.id, paths}]
        _none -> []
      end
    end)
    |> Map.new()
  end

  defp resolve(provider) when is_function(provider, 0), do: provider.()
  defp resolve(provider), do: provider

  defp configure(profile, provider, opts) do
    extra = Keyword.get(opts, :session, [])

    profile_opts =
      [provider: provider, tool_registry: Keyword.get(opts, :tool_registry, [])] ++
        Keyword.take(opts, [:sessions_dir, :store, :supervisor, :timeout_ms])

    with {:ok, options, effective} <- Profile.configure(profile, profile_opts) do
      session = Keyword.merge(Keyword.get(options, :session_options, []), extra)
      {:ok, Keyword.put(options, :session_options, session), effective}
    end
  end

  defp select_tasks(plan, %Manifest{tasks: tasks}, nil) do
    known = MapSet.new(plan.development_case_ids ++ plan.validation_case_ids)

    select_tasks(
      plan,
      %Manifest{tasks: tasks},
      Enum.filter(Enum.map(tasks, & &1.id), &(&1 in known))
    )
  end

  defp select_tasks(plan, %Manifest{tasks: tasks}, case_ids) when is_list(case_ids) do
    known = MapSet.new(plan.development_case_ids ++ plan.validation_case_ids)
    index = Map.new(tasks, &{&1.id, &1})

    cond do
      case_ids == [] ->
        {:error, :no_cases_selected}

      unknown = Enum.find(case_ids, &(not MapSet.member?(known, &1))) ->
        {:error, {:case_not_in_plan, unknown}}

      missing = Enum.find(case_ids, &(not Map.has_key?(index, &1))) ->
        {:error, {:case_not_in_manifest, missing}}

      true ->
        {:ok, Enum.map(case_ids, &Map.fetch!(index, &1))}
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {key, :required}}
    end
  end

  defp evaluation(plan, candidate, result, opts) do
    case_id = result["task_id"]
    observation = result["observation"] || %{}

    with {:ok, split} <- split(plan, case_id),
         {:ok, objectives} <- objectives(plan, result, observation) do
      {artifacts, references} = transcript_artifact(plan, observation)
      safety = safety(result, observation, case_id, opts)

      attrs = %{
        "id" => "eval_#{candidate.id}_#{case_id}_#{result["attempt"] || 1}",
        "scope" => plan.scope,
        "case_id" => case_id,
        "split" => split,
        "objectives" => objectives,
        "safety" => safety,
        "completeness" => completeness(result, observation, opts),
        "usage" => usage(observation),
        "cost" => %{"usd" => get_in(observation, ["usage", "cost_usd"])},
        "latency" => %{"milliseconds" => result["wall_time_ms"] || 0},
        "artifacts" => Enum.map(references, &ArtifactReference.to_map/1),
        "within_budget" =>
          observation["finish_reason"] not in @evaluator_stops and
            not provider_stream_timeout?(result),
        "terminal" => true,
        "observations" => observations(result, observation)
      }

      with {:ok, evaluation} <- Evaluation.new(plan, candidate, attrs) do
        {:ok, evaluation, artifacts}
      end
    end
  end

  defp split(plan, case_id) do
    cond do
      case_id in plan.development_case_ids -> {:ok, "development"}
      case_id in plan.validation_case_ids -> {:ok, "validation"}
      true -> {:error, {:case_not_in_plan, case_id}}
    end
  end

  defp objectives(plan, result, observation) do
    plan.objectives
    |> Enum.reduce_while({:ok, %{}}, fn %{"name" => name}, {:ok, values} ->
      # `task_success@model` reads the same fact as `task_success` on a
      # single-model run; the model-specific meaning only exists once several
      # models are merged.
      case objective(name |> String.split("@", parts: 2) |> hd(), result, observation) do
        value when is_number(value) -> {:cont, {:ok, Map.put(values, name, value * 1.0)}}
        nil -> {:halt, {:error, {:objective_unknown, name, result["task_id"]}}}
        :unknown_objective -> {:halt, {:error, {:unknown_objective, name}}}
      end
    end)
  end

  defp objective("task_success", result, _observation),
    do: if(result["passed"] == true, do: 1.0, else: 0.0)

  defp objective("wall_time_ms", result, _observation), do: result["wall_time_ms"]

  defp objective("requests", _result, observation),
    do: get_in(observation, ["tool_metrics", "requests"])

  defp objective("tool_calls", _result, observation),
    do: get_in(observation, ["tool_metrics", "calls"])

  defp objective("tool_errors", _result, observation),
    do: get_in(observation, ["tool_metrics", "errors"])

  defp objective("catalog_bytes", _result, observation),
    do: get_in(observation, ["tool_metrics", "catalog_bytes"])

  defp objective("cost_usd", _result, observation), do: get_in(observation, ["usage", "cost_usd"])
  defp objective("answer_bytes", _result, observation), do: byte_size(observation["answer"] || "")

  defp objective(name, _result, observation)
       when name in ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens),
       do: get_in(observation, ["usage", name])

  defp objective("total_tokens", _result, observation) do
    case observation["usage"] do
      %{"input_tokens" => input, "output_tokens" => output}
      when is_number(input) and is_number(output) ->
        input + output

      _unknown ->
        nil
    end
  end

  defp objective(_name, _result, _observation), do: :unknown_objective

  defp safety(_result, observation, case_id, opts) do
    allowlists = Keyword.get(opts, :allowed_changed_paths, %{})
    changed = observation["changed_paths"] || []

    outside =
      case Map.fetch(allowlists, case_id) do
        {:ok, allowed} -> Enum.reject(changed, &Gate.allowed_path?(&1, allowed))
        :error -> []
      end

    reported =
      case observation["safety_violations"] do
        violations when is_list(violations) -> violations
        _unknown -> []
      end

    failures =
      Enum.map(outside, &"changed_path_outside_allowlist:#{&1}") ++
        Enum.map(reported, &"sandbox_violation:#{inspect(&1)}")

    %{"passed" => failures == [], "failures" => failures}
  end

  defp completeness(result, observation, opts) do
    usage = observation["usage"] || %{}

    %{
      "usage" => usage_state(observation),
      "cost" => cost_state(usage, Keyword.get(opts, :unknown_cost, "reject")),
      "sandbox" =>
        sandbox_state(observation["safety_violations"], Keyword.get(opts, :sandbox, :required)),
      "artifacts" => artifacts_state(observation["transcript"]),
      "grader" => grader_state(result["grader"])
    }
  end

  defp usage_state(observation) when observation == %{}, do: "unknown"

  defp usage_state(observation) do
    usage = observation["usage"] || %{}
    metrics = observation["tool_metrics"] || %{}

    if is_number(usage["requests"]) and usage["requests"] == metrics["requests"],
      do: "complete",
      else: "partial"
  end

  defp cost_state(%{"cost_usd" => cost}, _unknown_cost) when is_number(cost), do: "complete"
  defp cost_state(_usage, "allow"), do: "not_applicable"
  defp cost_state(_usage, _unknown_cost), do: "unknown"

  defp sandbox_state(violations, _sandbox) when is_list(violations), do: "complete"
  defp sandbox_state(_violations, :not_applicable), do: "not_applicable"
  defp sandbox_state(_violations, _sandbox), do: "unknown"

  defp artifacts_state(transcript) when is_list(transcript), do: "complete"
  defp artifacts_state(_transcript), do: "unknown"

  defp grader_state(grader) when is_map(grader), do: "complete"
  defp grader_state(_grader), do: "unknown"

  defp usage(observation) do
    usage = observation["usage"] || %{}

    total =
      case usage do
        %{"input_tokens" => input, "output_tokens" => output}
        when is_number(input) and is_number(output) ->
          input + output

        _unknown ->
          nil
      end

    usage
    |> Map.take(~w(requests input_tokens output_tokens cache_read_tokens cache_write_tokens))
    |> Map.put("total_tokens", total)
  end

  defp transcript_artifact(plan, %{"transcript" => entries, "session_id" => session_id})
       when is_list(entries) do
    bytes = JSON.encode!(entries)

    reference =
      ArtifactReference.from_bytes("transcript", bytes,
        id: "transcript_#{session_id}",
        media_type: "application/json",
        content_schema: "lemieux.transcript.entries/v2",
        scope: plan.scope
      )

    {%{reference.sha256 => bytes}, [reference]}
  end

  defp transcript_artifact(_plan, _observation), do: {%{}, []}

  defp observations(result, observation) do
    %{
      "attempt" => result["attempt"] || 1,
      "status" => observation["status"],
      "finish_reason" => observation["finish_reason"],
      # The retained report has to say which of a run's failures was the
      # provider's and what it cost to get an answer anyway. `retries` is the
      # discarded tries, so an attempt that needed two connections is still
      # one sample and says so.
      "provider_error" => observation["provider_error"],
      "retries" => result["retries"] || [],
      "passed" => result["passed"] == true,
      "grader" => grader(result["grader"]),
      "error" => result["error"],
      "changed_paths" => observation["changed_paths"] || [],
      "tool_metrics" =>
        Map.take(
          observation["tool_metrics"] || %{},
          ~w(requests calls errors denied unavailable timeouts)
        ),
      "answer_bytes" => byte_size(observation["answer"] || "")
    }
  end

  defp grader(%{} = grader), do: Map.take(grader, ~w(passed exit_status timed_out))
  defp grader(_grader), do: nil
end
