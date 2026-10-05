defmodule Lemieux.Learning.Extension.Confirmation do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  One selected frozen extension, one preregistered independent comparison.

  `prepare/6` accepts a `Lemieux.Benchmark.Corpus` with complete direct/derived
  exposure history, frozen control and candidate builds, and an ordinary
  `Lemieux.Experiment.Plan` attribute map. It freezes holdout workspaces and an
  explicit evaluator directory before dispatch. Each task needs a `cluster_id`
  in metadata; related cases/repetitions count as one cluster. Exposed IDs,
  duplicate input content and clusters shared with development are refused.
  Hosts remain responsible for truthful membership and recording exposures
  outside this workbench; new IDs cannot establish independence by themselves.

  Grader command[0] is relative to `:evaluator_root`. Package all evaluator
  scripts/assets there; other arguments must be literals or benchmark
  placeholders. Interpreters, OS libraries and environment remain host-owned;
  this is not a hermetic or hostile-code evaluator. Never put evaluator secrets
  in candidate workspaces. Confirmation directories belong outside workbenches
  and package sources and must remain private to the evaluation host.

  `run/2` creates an exclusive exposure record before dispatch. An interrupted
  or completed experiment cannot be retried in the same directory. Persist the
  returned exposure through the host corpus ledger even after interruption.
  A new experiment requires fresh independent cases, not deletion of the marker.

  Plans use continuous paired cluster pass rates and the existing experiment
  decision interval. `extension_policy` declares repetitions, a reservation,
  total dollar budget, candidate mean latency limit, optional total token cap,
  and whether unknown dollars are allowed. Quota policies instead reserve an
  explicit total request allowance and a bound per attempt, including both arms;
  missing or excessive direct request counts fail the resource gate. These
  counts are not the provider's remaining quota. Allowing unknown dollars makes no
  efficiency claim. A pass is conditional on this declared corpus/evaluator,
  trusted configuration, and compatibility profile, never general efficacy.

  An optional `:discovery_candidate` uses the existing one-way discovery bridge;
  its content must be the canonical build manifest with `sha256` omitted.
  Neither confirmation nor export activates a host or changes its permissions.
  """

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Contract
  alias Lemieux.Experiment.Plan
  alias Lemieux.Learning.Discovery.Confirmation, as: DiscoveryConfirmation
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Confirmation.Evidence
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Tree
  alias Lemieux.Learning.Extension.Workbench.Project

  @type t :: %__MODULE__{root: Path.t(), sha256: String.t()}
  @enforce_keys [:root, :sha256]
  defstruct [:root, :sha256]

  @doc "Freezes one selected comparison and private evaluator without running either agent."
  @spec prepare(
          destination :: Path.t(),
          control :: Build.t(),
          candidate :: Build.t(),
          corpus :: Corpus.t(),
          attrs :: map(),
          opts :: keyword()
        ) ::
          {:ok, t()} | {:error, term()}
  def prepare(destination, control, candidate, corpus, attrs, opts \\ []) do
    root = Path.expand(destination)
    policy = attrs["extension_policy"]

    with :ok <- Build.verify(control),
         :ok <- Build.verify(candidate),
         :ok <- policy(policy),
         :ok <- independent(corpus),
         :ok <- experiment_policy(attrs, corpus),
         :ok <-
           separate(root, [
             control.root,
             candidate.root,
             Keyword.fetch!(opts, :evaluator_root) | Enum.map(corpus.manifest.tasks, & &1.cwd)
           ]),
         :ok <- File.mkdir(root),
         :ok <- File.chmod(root, 0o700) do
      result = prepare_into(root, control, candidate, corpus, attrs, opts)
      if match?({:error, _}, result), do: File.rm_rf(root)
      result
    end
  end

  @doc "Reopens a preregistration against its externally retained expected digest."
  @spec open(root :: Path.t(), digest :: String.t()) :: {:ok, t()} | {:error, term()}
  def open(root, digest) do
    handle = %__MODULE__{root: Path.expand(root), sha256: digest}
    with {:ok, _receipt} <- frozen(handle), do: {:ok, handle}
  end

  @doc "Runs once, retaining private full evidence and an exposure record before dispatch."
  @spec run(confirmation :: t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  def run(handle, opts \\ []) do
    with {:ok, receipt} <- frozen(handle),
         {:ok, control, candidate} <- builds(handle, receipt),
         :ok <- authorize(control, candidate, opts),
         :ok <- claim(handle, receipt),
         {:ok, manifest} <- manifest(handle),
         {:ok, report} <-
           Benchmark.run(manifest, runtimes(control, candidate, opts), run_options(receipt)),
         :ok <- Tree.write(Path.join(handle.root, "report.json"), report),
         {:ok, _receipt} <- frozen(handle),
         {:ok, verdict} <- evaluate(receipt, report),
         result =
           Map.merge(verdict, %{
             "confirmation_sha256" => handle.sha256,
             "report_sha256" => Contract.digest(report)
           }),
         :ok <- Tree.write(Path.join(handle.root, "result.json"), result) do
      {:ok, result}
    end
  end

  @doc "Returns the durable content-free exposure marker, including after a failed run."
  @spec exposure(confirmation :: t()) :: {:ok, Exposure.t()} | {:error, term()}
  def exposure(handle) do
    with {:ok, bytes} <- File.read(Path.join(handle.root, "exposure.json")),
         do: Exposure.decode(bytes)
  end

  @doc "Exports exactly the passing candidate source with a separate, content-free evidence receipt."
  @spec export(confirmation :: t(), destination :: Path.t()) :: {:ok, map()} | {:error, term()}
  def export(handle, destination) do
    with {:ok, candidate, receipt} <- qualification(handle),
         {:ok, _exported} <- Export.export(Path.join(candidate.root, "source"), destination),
         :ok <- verify_export(handle, destination, receipt) do
      {:ok, receipt}
    end
  end

  @doc "Verifies exported source and its receipt against private evidence and the pinned confirmation."
  @spec verify_export(confirmation :: t(), source :: Path.t(), receipt :: map()) ::
          :ok | {:error, term()}
  def verify_export(handle, source, receipt) do
    with {:ok, _candidate, expected} <- qualification(handle),
         :ok <- Export.verify(source),
         {:ok, exported} <- Tree.read(Path.join(source, "lemieux-extension-export.json")),
         true <- receipt == expected and exported["sha256"] == expected["source_sha256"] do
      :ok
    else
      false -> {:error, :confirmation_receipt_mismatch}
      error -> error
    end
  end

  defp qualification(handle) do
    with {:ok, receipt} <- frozen(handle),
         :ok <- exposed_for_plan(handle, receipt),
         {:ok, saved} <- Tree.read(Path.join(handle.root, "result.json")),
         {:ok, report} <- Tree.read(Path.join(handle.root, "report.json")),
         true <-
           saved["confirmation_sha256"] == handle.sha256 and
             saved["report_sha256"] == Contract.digest(report),
         {:ok, verdict} <- evaluate(receipt, report),
         true <- verdict["verdict"] == "pass",
         {:ok, _control, candidate} <- builds(handle, receipt),
         {:ok, source} <-
           Tree.read(Path.join([candidate.root, "source", "lemieux-extension-export.json"])) do
      # Keep hidden membership, results and graders out of the installable tree.
      assessment = %{
        "schema_version" => 1,
        "qualification" => "confirmed",
        "source_sha256" => source["sha256"],
        "build_sha256" => candidate.sha256,
        "confirmation_sha256" => handle.sha256,
        "report_sha256" => Contract.digest(report),
        "profile" => receipt["profiles"]["variant"],
        "verdict" => verdict,
        "production_active" => false
      }

      {:ok, candidate, Map.put(assessment, "sha256", Contract.digest(assessment))}
    else
      false -> {:error, :confirmation_not_exportable}
      error -> error
    end
  end

  defp exposed_for_plan(handle, receipt) do
    with {:ok, exposure} <- exposure(handle) do
      if exposure.context_digest == handle.sha256 and
           exposure.experiment_id == receipt["plan"]["id"] and
           exposure.source_case_ids == Enum.sort(receipt["plan"]["sample"]["holdout_case_ids"]),
         do: :ok,
         else: {:error, :confirmation_exposure_mismatch}
    end
  end

  defp prepare_into(root, control, candidate, corpus, attrs, opts) do
    directory = Path.join(root, "frozen")
    File.mkdir!(directory)
    tasks = Corpus.cases(corpus, :holdout)

    with :ok <- Tree.copy(control.root, Path.join(directory, "control")),
         :ok <- Tree.copy(candidate.root, Path.join(directory, "variant")),
         :ok <-
           Tree.copy(Keyword.fetch!(opts, :evaluator_root), Path.join(directory, "evaluator")),
         {:ok, definitions} <- copy_cases(directory, tasks),
         {:ok, evaluator_runtime} <- evaluator_runtime(directory, definitions, opts),
         :ok <-
           Tree.write(Path.join(directory, "suite.json"), %{
             "version" => 1,
             "tasks" => definitions
           }),
         {:ok, plan} <- plan(control, candidate, corpus, attrs, opts),
         {:ok, control_profile} <- Build.profile(control),
         {:ok, candidate_profile} <- Build.profile(candidate),
         :ok <- profile_budgets([control_profile, candidate_profile], attrs["extension_policy"]),
         {:ok, sealed} <-
           Tree.seal(directory, "confirmation.json", %{
             "schema_version" => 1,
             "plan" => Plan.to_map(plan),
             "policy" => attrs["extension_policy"],
             "builds" => %{"control" => control.sha256, "variant" => candidate.sha256},
             "profiles" => %{"control" => control_profile, "variant" => candidate_profile},
             "evaluator_runtime" => evaluator_runtime,
             "tasks" => definitions
           }) do
      {:ok, %__MODULE__{root: root, sha256: sealed["sha256"]}}
    end
  end

  defp profile_budgets(profiles, policy) do
    if Enum.all?(profiles, &profile_budget?(&1, policy)),
      do: :ok,
      else: {:error, :profile_exceeds_attempt_reservation}
  end

  defp profile_budget?(%{"execution" => "scripted"}, _policy), do: true

  defp profile_budget?(profile, %{"usage_mode" => "quota"} = policy) do
    options = profile["options"]

    options["usage_mode"] == "quota" and is_integer(options["max_requests"]) and
      options["max_requests"] <= policy["max_requests_per_attempt"]
  end

  defp profile_budget?(profile, policy) do
    cap = profile["options"]["max_cost_usd"]
    is_number(cap) and cap > 0 and cap <= policy["max_cost_per_attempt_usd"]
  end

  defp plan(control, candidate, corpus, attrs, opts) do
    development = Enum.reject(corpus.manifest.tasks, &(corpus.membership[&1.id] == :holdout))

    attrs =
      attrs
      |> Map.delete("extension_policy")
      |> Map.put("control", %{"digest" => control.sha256})
      |> Map.put("sample", %{
        "development_case_ids" => Enum.map(development, & &1.id),
        "holdout_case_ids" => Enum.map(Corpus.cases(corpus, :holdout), & &1.id)
      })

    case opts[:discovery_candidate] do
      nil ->
        Plan.new(
          Map.put(attrs, "variant", %{
            "digest" => candidate.sha256,
            "changes" => [%{"field" => "extension_build", "to" => candidate.sha256}]
          })
        )

      discovery ->
        with {:ok, receipt} <- Tree.read(Path.join(candidate.root, "build.json")),
             :ok <- discovery_exposure(discovery, Enum.map(development, & &1.id)),
             true <- discovery.content.sha256 == candidate.sha256 do
          DiscoveryConfirmation.to_experiment(
            discovery,
            Contract.encode!(Map.delete(receipt, "sha256")),
            attrs
          )
        else
          false -> {:error, :discovery_build_mismatch}
          error -> error
        end
    end
  end

  defp discovery_exposure(candidate, visible) do
    valid =
      candidate.interface_validation["status"] == "passed" and
        Enum.all?(candidate.exposures, fn
          %{"source_case_ids" => ids} when is_list(ids) -> Enum.all?(ids, &(&1 in visible))
          _other -> false
        end)

    if valid, do: :ok, else: {:error, :discovery_exposure_not_in_visible_corpus}
  end

  defp copy_cases(directory, tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      cwd = "cases/" <> to_string(index)
      [executable | args] = task.grader.command
      evaluator = Path.join(directory, "evaluator")

      with {:ok, ^executable} <- Path.safe_relative(executable, evaluator),
           true <- File.regular?(Path.join(evaluator, executable)),
           :ok <- Tree.copy(task.cwd, Path.join(directory, cwd)) do
        definition =
          Project.task(task)
          |> Map.put("cwd", cwd)
          |> put_in(["grader", "command"], ["evaluator/" <> executable | args])

        {:cont, {:ok, [definition | acc]}}
      else
        _error -> {:halt, {:error, {:invalid_confirmation_case, task.id}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp independent(corpus) do
    hidden = Corpus.cases(corpus, :holdout)
    visible = Enum.reject(corpus.manifest.tasks, &(&1 in hidden))
    clusters = Enum.map(hidden, & &1.metadata["cluster_id"])
    visible_clusters = Enum.map(visible, & &1.metadata["cluster_id"])

    cond do
      hidden == [] or visible == [] ->
        {:error, :missing_confirmation_split}

      not Enum.all?(clusters ++ visible_clusters, &(is_binary(&1) and &1 != "")) ->
        {:error, :cluster_ids_required}

      not MapSet.disjoint?(MapSet.new(clusters), MapSet.new(visible_clusters)) ->
        {:error, :exposed_cluster}

      Enum.any?(hidden, &(Corpus.exposures(corpus, &1.id) != [])) ->
        {:error, :confirmation_case_exposed}

      true ->
        distinct_inputs(hidden, visible)
    end
  end

  defp distinct_inputs(hidden, visible) do
    with {:ok, hidden_hashes} <- fingerprints(hidden),
         {:ok, visible_hashes} <- fingerprints(visible) do
      unique_clusters =
        Enum.zip(hidden, hidden_hashes)
        |> Enum.group_by(&elem(&1, 1))
        |> Enum.all?(&single_cluster?/1)

      if unique_clusters and
           MapSet.disjoint?(MapSet.new(hidden_hashes), MapSet.new(visible_hashes)),
         do: :ok,
         else: {:error, :exposed_case_content}
    end
  end

  defp single_cluster?({_hash, entries}) do
    entries
    |> Enum.map(fn {task, _hash} -> task.metadata["cluster_id"] end)
    |> Enum.uniq()
    |> length() == 1
  end

  defp fingerprints(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, hashes} ->
      case Tree.files(task.cwd) do
        {:ok, files} ->
          {:cont, {:ok, [Contract.digest(%{"prompt" => task.prompt, "files" => files}) | hashes]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp separate(root, paths) do
    if Enum.any?(
         paths,
         &(root == Path.expand(&1) or String.starts_with?(root, Path.expand(&1) <> "/"))
       ), do: {:error, :confirmation_directory_inside_inputs}, else: :ok
  end

  defp experiment_policy(attrs, corpus) do
    clusters =
      Corpus.cases(corpus, :holdout) |> Enum.map(& &1.metadata["cluster_id"]) |> Enum.uniq()

    metric = attrs["metric"] || %{}
    stopping = attrs["stopping_rule"] || %{}
    budget = attrs["budget"] || %{}

    allowed =
      ~w(hypothesis metric stopping_rule budget extension_policy provenance id created_at code_gate target development_validation_evaluations)

    if Enum.all?(Map.keys(attrs), &(&1 in allowed)) and metric?(metric) and
         sample?(stopping, clusters) and
         matched_budget?(
           budget,
           attrs["extension_policy"],
           length(Corpus.cases(corpus, :holdout))
         ),
       do: :ok,
       else: {:error, :invalid_cluster_experiment}
  end

  defp matched_budget?(budget, %{"usage_mode" => "quota"} = policy, cases) do
    budget["usage_mode"] == "quota" and budget["maximum_requests"] == policy["maximum_requests"] and
      cases * 2 * policy["repetitions"] * policy["max_requests_per_attempt"] <=
        policy["maximum_requests"]
  end

  defp matched_budget?(budget, policy, _cases),
    do: budget["maximum_cost_usd"] == policy["maximum_cost_usd"]

  defp metric?(%{"kind" => "continuous", "minimum_effect" => effect})
       when is_number(effect) and effect > 0, do: true

  defp metric?(_metric), do: false

  defp sample?(%{"minimum_pairs" => pairs}, clusters) when is_integer(pairs) and pairs >= 2,
    do: length(clusters) >= pairs

  defp sample?(_stopping, _clusters), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp policy(%{"usage_mode" => "quota"} = policy) do
    valid =
      Enum.all?(
        ~w(repetitions maximum_requests max_requests_per_attempt),
        &positive_integer?(policy[&1])
      ) and
        is_number(policy["maximum_mean_latency_ms"]) and policy["maximum_mean_latency_ms"] > 0 and
        policy["maximum_cost_usd"] == nil and policy["max_cost_per_attempt_usd"] == nil and
        policy["unknown_cost"] == "allow" and
        (policy["maximum_total_tokens"] == nil or
           positive_integer?(policy["maximum_total_tokens"]))

    if valid, do: :ok, else: {:error, :invalid_confirmation_policy}
  end

  defp policy(policy) when is_map(policy) do
    required =
      ~w(repetitions maximum_cost_usd max_cost_per_attempt_usd maximum_mean_latency_ms unknown_cost)

    valid =
      Enum.all?(required, &Map.has_key?(policy, &1)) and
        positive_integer?(policy["repetitions"]) and
        Enum.all?(
          ~w(maximum_cost_usd max_cost_per_attempt_usd maximum_mean_latency_ms),
          &(is_number(policy[&1]) and policy[&1] > 0)
        ) and
        policy["max_cost_per_attempt_usd"] <= policy["maximum_cost_usd"] and
        policy["unknown_cost"] in ~w(allow reject) and
        (policy["maximum_total_tokens"] == nil or
           positive_integer?(policy["maximum_total_tokens"]))

    if valid, do: :ok, else: {:error, :invalid_confirmation_policy}
  end

  defp policy(_other), do: {:error, :invalid_confirmation_policy}

  defp frozen(handle) do
    with {:ok, receipt} <-
           Tree.verify(Path.join(handle.root, "frozen"), "confirmation.json", handle.sha256),
         {:ok, current} <- executable_hashes(Map.keys(receipt["evaluator_runtime"])),
         true <- current == receipt["evaluator_runtime"] do
      {:ok, receipt}
    else
      false -> {:error, :evaluator_runtime_changed}
      error -> error
    end
  end

  defp evaluator_runtime(directory, tasks, opts) do
    interpreters =
      Enum.flat_map(tasks, fn task ->
        [executable | _args] = task["grader"]["command"]

        case File.read!(Path.join(directory, executable)) do
          <<"#!", rest::binary>> ->
            rest |> String.split("\n", parts: 2) |> hd() |> String.split() |> interpreter()

          _binary ->
            []
        end
      end)

    executable_hashes(Enum.uniq(interpreters ++ Keyword.get(opts, :evaluator_runtime, [])))
  end

  defp interpreter(["/usr/bin/env", program]), do: ["/usr/bin/env", program]
  defp interpreter(["/usr/bin/env" | _args]), do: ["unsupported-env-shebang"]
  defp interpreter([program | _args]), do: [program]
  defp interpreter([]), do: ["missing-shebang-interpreter"]

  defp executable_hashes(programs) do
    Enum.reduce_while(programs, {:ok, %{}}, fn program, {:ok, hashes} ->
      path = System.find_executable(program)

      case read_executable(path) do
        {:ok, bytes} ->
          {:cont,
           {:ok, Map.put(hashes, program, %{"path" => path, "sha256" => Contract.sha256(bytes)})}}

        _error ->
          {:halt, {:error, {:missing_evaluator_runtime, program}}}
      end
    end)
  end

  defp read_executable(nil), do: {:error, :enoent}
  defp read_executable(path), do: File.read(path)

  defp builds(handle, receipt) do
    with {:ok, control} <-
           Build.open(Path.join([handle.root, "frozen", "control"]), receipt["builds"]["control"]),
         {:ok, candidate} <-
           Build.open(Path.join([handle.root, "frozen", "variant"]), receipt["builds"]["variant"]),
         do: {:ok, control, candidate}
  end

  defp authorize(control, candidate, opts) do
    with {:ok, left} <- Build.profile(control), {:ok, right} <- Build.profile(candidate) do
      if "live" in [left["execution"], right["execution"]] and opts[:allow_live] != true,
        do: {:error, :live_confirmation_required},
        else: :ok
    end
  end

  defp claim(handle, receipt) do
    {:ok, exposure} =
      Exposure.new(%{
        "id" => Lemieux.ID.generate(),
        "consumer_role" => "confirmation_evaluator",
        "consumer_id" => receipt["plan"]["id"],
        "experiment_id" => receipt["plan"]["id"],
        "context_digest" => handle.sha256,
        "direct_case_ids" => receipt["plan"]["sample"]["holdout_case_ids"],
        "source_case_ids" => receipt["plan"]["sample"]["holdout_case_ids"],
        "derived_artifact_ids" => []
      })

    Tree.write(Path.join(handle.root, "exposure.json"), Exposure.to_map(exposure))
  end

  defp manifest(handle) do
    directory = Path.join(handle.root, "frozen")

    with {:ok, suite} <- Tree.read(Path.join(directory, "suite.json")) do
      tasks =
        Enum.map(suite["tasks"], fn task ->
          [executable | args] = task["grader"]["command"]
          put_in(task, ["grader", "command"], [Path.join(directory, executable) | args])
        end)

      Manifest.from_map(Map.put(suite, "tasks", tasks), directory)
    end
  end

  defp runtimes(control, candidate, opts),
    do: [
      Runtime.new("control", Runtime.Frozen, [build: control] ++ opts),
      Runtime.new("variant", Runtime.Frozen, [build: candidate] ++ opts)
    ]

  defp run_options(receipt) do
    policy = receipt["policy"]

    [
      workspace: :copy,
      repetitions: policy["repetitions"],
      max_concurrency: 1,
      cost_cap_usd: policy["maximum_cost_usd"],
      max_cost_per_attempt_usd: policy["max_cost_per_attempt_usd"]
    ]
  end

  defp evaluate(receipt, report) do
    with {:ok, plan} <- Plan.new(receipt["plan"]),
         do: Evidence.evaluate(plan, receipt["policy"], receipt["tasks"], report)
  end
end
