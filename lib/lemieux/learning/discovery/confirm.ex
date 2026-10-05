defmodule Lemieux.Learning.Discovery.Confirm do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Independent confirmation of one discovered profile candidate, on cases the
  search never saw, optionally on a different model.

  Discovery is allowed to overfit: it reads its own development traces and
  proposes against them. What it may not do is decide. This lane is the
  decision's evidence: a preregistered `Lemieux.Experiment.Plan` built by
  `Lemieux.Learning.Discovery.Confirmation.to_experiment/3`, paired control
  and variant sessions on the manifest cases that were neither development
  nor validation members of the plan, cluster means so related cases cannot
  inflate the sample, and the anytime-valid `e_process` rule by default.

  Two research results shape the defaults. "Harness Updating Is Not Harness
  Benefit" separates the capability to *use* an improved harness from the
  capability to propose one, and reports that gains often fail to transfer;
  AHE and the Mendel Gödel Machine both report that structural edits transfer
  across model families while prose does not. So the lane can run both arms
  on a **target model** that differs from the search model: a candidate found
  cheaply on a small model is confirmed where it will be used. The swap is
  applied identically to both arms and recorded in the plan's control
  reference, never as a change to the candidate's own bytes.

  Each confirmation directory is single-use. The holdout exposure marker is
  written before the first session starts, and a second run in the same
  directory is refused: rerunning the same cases does not make them
  independent again. Nothing here activates anything.
  """

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Gate
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Agent, as: AgentRuntime
  alias Lemieux.Contract
  alias Lemieux.Experiment.Decision
  alias Lemieux.Experiment.Plan, as: ExperimentPlan
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Confirmation
  alias Lemieux.Learning.Discovery.Evaluator
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Providers.Scripted

  @type prepared :: %{
          dir: Path.t(),
          plan: ExperimentPlan.t(),
          discovery_plan: Plan.t(),
          candidate: Candidate.t(),
          control: Candidate.t(),
          variant_profile: map(),
          control_profile: map(),
          tasks: [Lemieux.Benchmark.Task.t()],
          manifest: Manifest.t(),
          policy: map()
        }

  @typedoc "The two arms of a confirmation as read from a campaign archive."
  @type arms :: %{
          plan: Plan.t(),
          candidate: Candidate.t(),
          control: Candidate.t(),
          variant_bytes: binary(),
          control_bytes: binary()
        }

  @doc """
  Resolves the two arms of a confirmation from the archive under
  `output_dir`: the frozen plan, the candidate named by `candidate_id` as the
  variant, the control (the seed candidate, or `opts[:control]`), and both
  candidates' content bytes.

  Shared with `Lemieux.Learning.Discovery.Meta.confirm/3` so that "which
  archive, which candidate, which control" is answered once; a lane that
  read the archive its own way would drift on exactly the questions a
  confirmation exists to settle.
  """
  @spec arms(output_dir :: Path.t(), candidate_id :: String.t(), opts :: keyword()) ::
          {:ok, arms()} | {:error, term()}
  def arms(output_dir, candidate_id, opts \\ [])
      when is_binary(output_dir) and is_binary(candidate_id) and is_list(opts) do
    with {:ok, plan} <- read_plan(output_dir),
         {:ok, candidates} <- read_candidates(output_dir, plan),
         {:ok, candidate} <- find(candidates, candidate_id),
         {:ok, control} <- control_candidate(candidates, Keyword.get(opts, :control)),
         {:ok, variant_bytes} <- read_artifact(output_dir, Candidate.content_sha256(candidate)),
         {:ok, control_bytes} <- read_artifact(output_dir, Candidate.content_sha256(control)) do
      {:ok,
       %{
         plan: plan,
         candidate: candidate,
         control: control,
         variant_bytes: variant_bytes,
         control_bytes: control_bytes
       }}
    end
  end

  @doc """
  Claims the single-use confirmation directory for `candidate_id` under
  `output_dir` (`confirmations/<candidate_id><suffix>`), refusing one that
  already exists. `opts[:suffix]` names a separate directory for a second
  confirmation of the same candidate, on another model or another lane.
  """
  @spec claim_directory(output_dir :: Path.t(), candidate_id :: String.t(), opts :: keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def claim_directory(output_dir, candidate_id, opts \\ [])
      when is_binary(output_dir) and is_binary(candidate_id) and is_list(opts) do
    dir = Path.join([output_dir, "confirmations", safe(candidate_id) <> suffix(opts)])
    with :ok <- fresh(dir), do: {:ok, dir}
  end

  @doc """
  Preregisters the confirmation for `candidate_id` from a campaign archive.

  Options: `:model` (target model for both arms; default the profile's own),
  `:control` (candidate id; default the seed candidate), `:holdout_case_ids`
  (default every manifest case outside the plan's development and validation
  ids), `:repetitions` (1), `:alpha` (0.05), `:minimum_effect` (0.1),
  `:minimum_pairs` (2), `:stopping_rule` (a complete rule map overriding the
  e-process default), `:max_cost_usd` (5.0), `:max_cost_per_attempt_usd`
  (0.25), `:max_requests_per_attempt` (24, quota only).
  """
  @spec prepare(config :: keyword(), candidate_id :: String.t(), opts :: keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(config, candidate_id, opts \\ [])
      when is_list(config) and is_binary(candidate_id) and is_list(opts) do
    with {:ok, output_dir} <- fetch(config, :output_dir),
         {:ok, manifest_path} <- fetch(config, :manifest),
         {:ok, manifest} <- Manifest.read(manifest_path),
         {:ok, arms} <- arms(output_dir, candidate_id, opts),
         %{
           plan: discovery_plan,
           candidate: candidate,
           control: control,
           variant_bytes: variant_bytes,
           control_bytes: control_bytes
         } = arms,
         {:ok, tasks} <-
           holdout_tasks(manifest, discovery_plan, Keyword.get(opts, :holdout_case_ids)),
         {:ok, variant_profile, control_profile, normalization} <-
           arm_profiles(variant_bytes, control_bytes, opts),
         policy = policy(variant_profile, tasks, opts),
         {:ok, plan} <-
           Confirmation.to_experiment(
             candidate,
             variant_bytes,
             experiment_attrs(
               discovery_plan,
               candidate,
               control,
               tasks,
               normalization,
               policy,
               opts
             )
           ),
         {:ok, dir} <- claim_directory(output_dir, candidate.id, opts),
         :ok <- File.write(Path.join(dir, "experiment-plan.json"), ExperimentPlan.encode!(plan)) do
      {:ok,
       %{
         dir: dir,
         plan: plan,
         discovery_plan: discovery_plan,
         candidate: candidate,
         control: control,
         variant_profile: variant_profile,
         control_profile: control_profile,
         tasks: tasks,
         manifest: manifest,
         policy: policy
       }}
    end
  end

  @doc """
  Prepares and runs the confirmation, writing `exposure.json`, `report.json`,
  `decision.json` and `result.json` under the confirmation directory.
  """
  @spec run(config :: keyword(), candidate_id :: String.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(config, candidate_id, opts \\ []) when is_list(config) and is_binary(candidate_id) do
    with {:ok, provider} <- fetch(config, :provider),
         :ok <- live_allowed(config, provider),
         {:ok, prepared} <- prepare(config, candidate_id, opts),
         {:ok, exposure} <- expose(prepared),
         :ok <-
           File.write(Path.join(prepared.dir, "exposure.json"), Exposure.encode!(exposure), [
             :exclusive
           ]),
         {:ok, report} <- benchmark(prepared, provider, config),
         :ok <- File.write(Path.join(prepared.dir, "report.json"), JSON.encode!(report)),
         {:ok, result} <- evaluate(prepared, report) do
      File.write!(Path.join(prepared.dir, "decision.json"), JSON.encode!(result["quality"]))
      File.write!(Path.join(prepared.dir, "result.json"), JSON.encode!(result))
      {:ok, result}
    end
  end

  @doc "Evaluates a completed paired report against the preregistered plan."
  @spec evaluate(prepared :: prepared(), report :: map()) :: {:ok, map()} | {:error, term()}
  def evaluate(prepared, report) when is_map(prepared) and is_map(report) do
    rows = report["results"] || []
    tasks = prepared.tasks
    policy = prepared.policy

    expected =
      for task <- tasks,
          attempt <- 1..policy["repetitions"],
          runtime <- ~w(control variant),
          do: {task.id, runtime, attempt}

    actual = Enum.map(rows, &{&1["task_id"], &1["runtime"], &1["attempt"]})
    allowlists = Evaluator.allowlists(tasks)

    cond do
      Enum.sort(expected) != Enum.sort(actual) -> {:error, :incomplete_confirmation}
      not Enum.all?(rows, &terminal?/1) -> {:error, :non_terminal_attempt}
      true -> decide(prepared, tasks, rows, allowlists, policy)
    end
  end

  defp decide(prepared, tasks, rows, allowlists, policy) do
    with {:ok, decision} <-
           Decision.evaluate(prepared.plan, %{
             "development" => [],
             "holdout" => pairs(tasks, rows),
             "safety_failures" => safety_failures(rows, allowlists),
             "critical_regressions" => critical_regressions(tasks, rows)
           }) do
      resources = resources(rows, policy)

      verdict =
        if resources["passed"] or
             decision.verdict in [:fail, :safety_failure, :critical_regression],
           do: to_string(decision.verdict),
           else: "inconclusive"

      {:ok,
       %{
         "verdict" => verdict,
         "reason" => to_string(decision.reason),
         "quality" => Contract.json(decision),
         "resources" => resources,
         "arms" => %{
           "control" => prepared.control.id,
           "variant" => prepared.candidate.id,
           "model" => prepared.variant_profile["model"]
         },
         "pairs" => pairs(tasks, rows),
         "per_case" => per_case(rows),
         "experiment_id" => prepared.plan.id,
         "experiment_sha256" => prepared.plan.sha256,
         "qualification" => "confirmation evidence only; nothing is activated"
       }}
    end
  end

  # ---------------------------------------------------------------------------

  defp benchmark(prepared, provider, config) do
    runtimes = [
      runtime("control", prepared.control_profile, provider, config, prepared.dir),
      runtime("variant", prepared.variant_profile, provider, config, prepared.dir)
    ]

    options =
      [
        repetitions: prepared.policy["repetitions"],
        workspace_root: Path.join(prepared.dir, "workspaces"),
        max_concurrency: 1
      ]
      |> Keyword.merge(Keyword.get(config, :benchmark, []))
      |> Keyword.drop([:output, :workspace])
      |> Keyword.merge(cost_options(prepared.policy))

    %Manifest{} = manifest = prepared.manifest
    Benchmark.run(%Manifest{manifest | tasks: prepared.tasks}, runtimes, options)
  end

  defp cost_options(%{"usage_mode" => "quota"}), do: []

  defp cost_options(policy),
    do: [
      cost_cap_usd: policy["maximum_cost_usd"],
      max_cost_per_attempt_usd: policy["max_cost_per_attempt_usd"]
    ]

  defp runtime(name, profile, provider, config, dir) do
    Runtime.new(name, AgentRuntime,
      agent: Lemieux.Agent.Session,
      agent_options: fn ->
        {:ok, options, _profile} =
          Profile.configure(profile,
            provider: resolve(provider),
            sessions_dir: Keyword.get(config, :sessions_dir, Path.join(dir, "sessions"))
          )

        session =
          Keyword.merge(
            Keyword.get(options, :session_options, []),
            Keyword.get(config, :session, [])
          )

        Keyword.put(options, :session_options, session)
      end
    )
  end

  defp arm_profiles(variant_bytes, control_bytes, opts) do
    with {:ok, variant} <- decode(variant_bytes),
         {:ok, control} <- decode(control_bytes) do
      target = Keyword.get(opts, :model, variant["model"])
      {variant, variant_changes} = normalize(variant, target, opts)
      {control, control_changes} = normalize(control, target, opts)

      with :ok <- Profile.validate(variant),
           :ok <- Profile.validate(control) do
        {:ok, variant, control,
         %{
           "confirmation_model" => target,
           "search_model" => decode!(variant_bytes)["model"],
           "variant" => variant_changes,
           "control" => control_changes
         }}
      end
    end
  end

  # Both arms receive the same target model and the same budget shape; the
  # normalization is recorded, not hidden.
  defp normalize(profile, target, opts) do
    Profile.retarget(
      profile,
      target,
      Keyword.take(opts, [:usage_mode, :max_cost_per_attempt_usd, :max_requests_per_attempt])
      |> Enum.map(fn
        {:max_cost_per_attempt_usd, cap} -> {:max_cost_usd, cap}
        {:max_requests_per_attempt, bound} -> {:max_requests, bound}
        other -> other
      end)
    )
  end

  defp policy(variant_profile, tasks, opts) do
    quota? = variant_profile["options"]["usage_mode"] == "quota"

    %{
      "repetitions" => Keyword.get(opts, :repetitions, 1),
      "usage_mode" => if(quota?, do: "quota", else: "metered"),
      "maximum_cost_usd" => Keyword.get(opts, :max_cost_usd, 5.0),
      "max_cost_per_attempt_usd" => Keyword.get(opts, :max_cost_per_attempt_usd, 0.25),
      "max_requests_per_attempt" => Keyword.get(opts, :max_requests_per_attempt, 24),
      "maximum_requests" =>
        Keyword.get(opts, :max_requests_per_attempt, 24) * length(tasks) * 2 *
          Keyword.get(opts, :repetitions, 1),
      "maximum_mean_latency_ms" =>
        Keyword.get(opts, :maximum_mean_latency_ms, :timer.minutes(15)),
      "unknown_cost" => if(quota?, do: "allow", else: "reject")
    }
  end

  defp experiment_attrs(discovery_plan, candidate, control, tasks, normalization, policy, opts) do
    clusters = tasks |> Enum.map(&get_in(&1.metadata, ["cluster_id"])) |> Enum.uniq()
    minimum_pairs = Keyword.get(opts, :minimum_pairs, min(2, length(clusters)))
    minimum_effect = Keyword.get(opts, :minimum_effect, 0.1)

    stopping_rule =
      Keyword.get(opts, :stopping_rule, %{
        "kind" => "e_process",
        "alpha" => Keyword.get(opts, :alpha, 0.05),
        "minimum_pairs" => minimum_pairs,
        "range" => [-1, 1]
      })

    budget =
      if policy["usage_mode"] == "quota",
        do: %{"usage_mode" => "quota", "maximum_requests" => policy["maximum_requests"]},
        else: %{"maximum_cost_usd" => policy["maximum_cost_usd"]}

    %{
      "hypothesis" =>
        get_in(candidate.extensions, ["hypothesis"]) ||
          "Candidate #{candidate.id} improves holdout task success over #{control.id}.",
      "control" =>
        Map.merge(
          %{"digest" => Candidate.content_sha256(control), "candidate_id" => control.id},
          normalization
        ),
      "metric" => %{
        "kind" => "continuous",
        "minimum_effect" => minimum_effect,
        "unit" => "cluster_pass_rate"
      },
      "sample" => %{
        "development_case_ids" => discovery_plan.development_case_ids,
        "holdout_case_ids" => Enum.map(tasks, & &1.id),
        "clusters" => clusters
      },
      "stopping_rule" => stopping_rule,
      "budget" => budget,
      "target" => "profile",
      "development_validation_evaluations" =>
        get_in(candidate.extensions, ["proposer_usage"]) || %{}
    }
  end

  defp expose(prepared) do
    manifest = prepared.manifest
    plan = prepared.discovery_plan
    holdout = MapSet.new(Enum.map(prepared.tasks, & &1.id))

    membership =
      Map.new(manifest.tasks, fn task ->
        cond do
          task.id in plan.development_case_ids -> {task.id, :development}
          task.id in plan.validation_case_ids -> {task.id, :validation}
          true -> {task.id, :holdout}
        end
      end)

    with {:ok, corpus} <- Corpus.new(manifest, membership),
         {:ok, corpus} <-
           Corpus.expose(corpus, MapSet.to_list(holdout), %{
             consumer_role: "confirmation_evaluator",
             consumer_id: prepared.plan.id,
             lineage_id: plan.id,
             model: prepared.variant_profile["model"],
             context_digest: prepared.plan.sha256,
             experiment_id: prepared.plan.id
           }) do
      [exposure | _] = Corpus.exposures(corpus, hd(prepared.tasks).id)
      {:ok, exposure}
    end
  end

  defp holdout_tasks(manifest, plan, nil) do
    seen = MapSet.new(plan.development_case_ids ++ plan.validation_case_ids)
    tasks = Enum.reject(manifest.tasks, &MapSet.member?(seen, &1.id))
    holdout_tasks(manifest, plan, Enum.map(tasks, & &1.id))
  end

  defp holdout_tasks(manifest, plan, ids) when is_list(ids) do
    seen = MapSet.new(plan.development_case_ids ++ plan.validation_case_ids)
    index = Map.new(manifest.tasks, &{&1.id, &1})

    cond do
      ids == [] ->
        {:error, :no_holdout_cases}

      exposed = Enum.find(ids, &MapSet.member?(seen, &1)) ->
        {:error, {:holdout_case_exposed_to_search, exposed}}

      missing = Enum.find(ids, &(not Map.has_key?(index, &1))) ->
        {:error, {:case_not_in_manifest, missing}}

      true ->
        clustered(Enum.map(ids, &Map.fetch!(index, &1)))
    end
  end

  defp clustered(tasks) do
    clusters =
      tasks
      |> Enum.map(&get_in(&1.metadata, ["cluster_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      Enum.any?(tasks, &is_nil(get_in(&1.metadata, ["cluster_id"]))) ->
        {:error, :holdout_case_without_cluster}

      length(clusters) < 2 ->
        {:error, :fewer_than_two_holdout_clusters}

      true ->
        {:ok, tasks}
    end
  end

  defp pairs(tasks, rows) do
    tasks
    |> Enum.group_by(&get_in(&1.metadata, ["cluster_id"]))
    |> Enum.sort()
    |> Enum.map(fn {_cluster, members} ->
      ids = Enum.map(members, & &1.id)
      group = Enum.filter(rows, &(&1["task_id"] in ids))
      Map.new(~w(control variant), &{&1, pass_rate(group, &1)})
    end)
  end

  defp pass_rate(group, runtime) do
    values =
      group
      |> Enum.filter(&(&1["runtime"] == runtime))
      |> Enum.map(&if(&1["passed"], do: 1.0, else: 0.0))

    if values == [], do: 0.0, else: Enum.sum(values) / length(values)
  end

  defp per_case(rows) do
    rows
    |> Enum.group_by(& &1["task_id"])
    |> Map.new(fn {id, group} ->
      {id, Map.new(group, &{"#{&1["runtime"]}/#{&1["attempt"]}", &1["passed"] == true})}
    end)
  end

  defp safety_failures(rows, allowlists) do
    Enum.flat_map(rows, fn row ->
      changed = get_in(row, ["observation", "changed_paths"]) || []

      outside =
        case Map.fetch(allowlists, row["task_id"]) do
          {:ok, allowed} ->
            Enum.reject(changed, &Gate.allowed_path?(&1, allowed))

          :error ->
            []
        end

      reported =
        case get_in(row, ["observation", "safety_violations"]) do
          violations when is_list(violations) -> violations
          _unknown -> []
        end

      Enum.map(
        outside,
        &%{"case_id" => row["task_id"], "runtime" => row["runtime"], "path" => &1}
      ) ++
        Enum.map(
          reported,
          &%{
            "case_id" => row["task_id"],
            "runtime" => row["runtime"],
            "violation" => Contract.json(&1)
          }
        )
    end)
  end

  defp critical_regressions(tasks, rows) do
    critical =
      tasks |> Enum.filter(&(get_in(&1.metadata, ["critical"]) == true)) |> Enum.map(& &1.id)

    rows
    |> Enum.filter(&(&1["task_id"] in critical))
    |> Enum.group_by(&{&1["task_id"], &1["attempt"]})
    |> Enum.flat_map(fn {{id, attempt}, pair} ->
      values = Map.new(pair, &{&1["runtime"], &1["passed"]})

      if values["control"] and not values["variant"],
        do: [%{"case_id" => id, "attempt" => attempt}],
        else: []
    end)
  end

  defp terminal?(row), do: is_map(row["observation"]) and is_boolean(row["passed"])

  defp resources(rows, policy) do
    variant = Enum.filter(rows, &(&1["runtime"] == "variant"))
    costs = Enum.map(rows, &get_in(&1, ["observation", "usage", "cost_usd"]))
    requests = Enum.map(rows, &get_in(&1, ["observation", "tool_metrics", "requests"]))

    latency = mean_latency(variant)
    known_cost = if Enum.all?(costs, &is_number/1), do: Enum.sum(costs), else: nil
    observed_cost = costs |> Enum.filter(&is_number/1) |> Enum.sum()

    %{
      "passed" =>
        cost_ok?(policy, known_cost) and requests_ok?(policy, requests) and
          latency <= policy["maximum_mean_latency_ms"],
      "cost_usd" => known_cost,
      "observed_cost_usd" => observed_cost,
      "direct_requests" => Enum.sum(Enum.filter(requests, &is_integer/1)),
      "usage_mode" => policy["usage_mode"],
      "variant_mean_latency_ms" => latency
    }
  end

  defp mean_latency([]), do: 0.0

  defp mean_latency(variant),
    do: Enum.sum(Enum.map(variant, &(&1["wall_time_ms"] || 0))) / length(variant)

  # A quota lane reports no dollars, so the cost cap only binds a metered one.
  defp cost_ok?(%{"usage_mode" => "quota"}, _known_cost), do: true

  defp cost_ok?(policy, known_cost),
    do: is_number(known_cost) and known_cost <= policy["maximum_cost_usd"]

  # Request bounds are the quota lane's budget; a metered lane is bound by cost.
  defp requests_ok?(%{"usage_mode" => "quota"} = policy, requests) do
    Enum.all?(requests, &(is_integer(&1) and &1 <= policy["max_requests_per_attempt"])) and
      Enum.sum(Enum.filter(requests, &is_integer/1)) <= policy["maximum_requests"]
  end

  defp requests_ok?(_policy, _requests), do: true

  # One candidate may be confirmed on several models; each gets its own
  # single-use directory so the exposure marker still means one run.
  defp suffix(opts) do
    case Keyword.get(opts, :suffix) do
      nil -> ""
      value -> "-" <> safe(to_string(value))
    end
  end

  defp control_candidate(candidates, nil) do
    case Enum.find(candidates, &(&1.mutation_kind == "seed")) do
      nil -> {:error, :seed_candidate_missing}
      seed -> {:ok, seed}
    end
  end

  defp control_candidate(candidates, id), do: find(candidates, id)

  defp find(candidates, id) do
    case Enum.find(candidates, &(&1.id == id)) do
      nil -> {:error, {:unknown_candidate, id}}
      candidate -> {:ok, candidate}
    end
  end

  defp read_plan(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "plan.json")), do: Plan.decode(bytes)
  end

  defp read_candidates(dir, plan) do
    path = Path.join(dir, "candidates")

    with {:ok, names} <- File.ls(path) do
      names |> Enum.sort() |> decode_candidates(plan, path)
    end
  end

  defp decode_candidates(names, plan, path) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, built} ->
      case Candidate.decode(plan, File.read!(Path.join(path, name))) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | built]}}
        {:error, reason} -> {:halt, {:error, {:archive_unreadable, name, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp read_artifact(dir, sha256) do
    case File.read(Path.join([dir, "artifacts", sha256])) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, {:candidate_content_missing, sha256}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :candidate_content_not_json}
    end
  end

  defp decode!(bytes), do: JSON.decode!(bytes)

  defp fresh(dir) do
    if File.exists?(dir), do: {:error, {:confirmation_dir_exists, dir}}, else: File.mkdir_p(dir)
  end

  defp live_allowed(config, provider) do
    cond do
      Keyword.get(config, :allow_live, false) == true -> :ok
      match?({Scripted, _}, resolve(provider)) -> :ok
      true -> {:error, :live_campaign_requires_allow_live}
    end
  end

  defp resolve(provider) when is_function(provider, 0), do: provider.()
  defp resolve(provider), do: provider

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp fetch(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
