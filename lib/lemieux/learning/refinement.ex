defmodule Lemieux.Learning.Refinement do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Explicit, checkpointed task-local propose/probe/compose over the effective
  harness. Hosts supply isolation, current identity bindings, a runtime factory,
  an evidence assessor and durable exposure commit. No scheduler starts here.
  A proposal is never applied to the user's workspace by this lane.

  The whole frozen experiment reserves inside the existing controller before
  any provider is resolved. Its funded child meters every physical request,
  including proposer work, failures and retries. All runtimes receive that
  controlled provider. A host proposer must use its supplied provider too.

  Each repetition gets a new host lease. The host attests confined replayable
  effects, equivalent clean inputs and matching model/harness/environment,
  policy, descriptor and verification identities. A transcript fork is not
  isolation. External/credential/unknown effects refuse work. The host destroys
  a lease, including its processes, when released; guardian ownership also
  releases it when the caller dies.

  Candidate bytes use the discovery plan, Candidate and Surface contracts.
  By default every candidate observation must beat every baseline observation
  without a regression. An explicitly frozen experimental mean policy is a
  task-local search heuristic and produces no ordinary promotion eligibility.
  Variability stays explicit. Conflicting
  edits are excluded; a composition is executed before selection. Without a
  verifier the result is behavioral/unconfirmed, never correctness or transfer.
  The original output/profile always remains in the receipt.

  `Agent.Checkpoint` commits an intent before effects and requires explicit
  reconciliation of in-doubt work; resume never replays it automatically.
  Callers own worker cancellation. Fresh authority and current isolation are
  required even when reusing a completed result.
  """
  alias Lemieux.Agent.Checkpoint
  alias Lemieux.Agent.Resource
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluator
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.ProfileDelta
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Refinement.Edits
  alias Lemieux.Learning.Refinement.Evidence
  alias Lemieux.Learning.Refinement.Support
  alias Lemieux.Learning.RuntimeEvidence

  @bindings ~w(source_sha256 harness_sha256 environment_sha256 descriptors_sha256 policy_sha256 verification_sha256 model_sha256)

  @doc "Checks the host's current, clean, effect-confined input without model work."
  @spec preflight(isolation :: term(), bindings :: map()) :: :ok | {:error, term()}
  def preflight(nil, _bindings), do: {:error, :isolation_required}

  def preflight({module, state}, bindings) when is_atom(module) do
    with {:ok, status} <- module.inspect(state),
         true <- status["isolated"] == true,
         true <- status["clean"] == true,
         ^bindings <- status["bindings"],
         effects when is_list(effects) <- status["effects"],
         true <- Enum.all?(effects, &(&1 in ~w(read workspace_write))) do
      :ok
    else
      _refused -> {:error, :isolation_or_inputs_changed}
    end
  rescue
    _failure -> {:error, :isolation_unavailable}
  end

  def preflight(_invalid, _bindings), do: {:error, :isolation_required}

  @doc "Runs a finite host-authorized experiment; returns a retained baseline or a scoped proposal."
  @spec run(handle :: Checkpoint.t(), key :: String.t(), plan :: Plan.t(), opts :: keyword()) ::
          term()
  def run(handle, key, %Plan{} = plan, opts) do
    with {:ok, config} <- configuration(plan, opts) do
      inputs = %{
        "workspace_snapshot" => config.bindings,
        "upstream_artifacts" => %{"plan" => plan.sha256, "request" => config.digest}
      }

      Checkpoint.step(handle, key, inputs, fn -> execute(plan, key, config, opts) end,
        validate: fn receipt ->
          with :ok <- verify(receipt), do: preflight(opts[:isolation], config.bindings)
        end
      )
    end
  end

  @doc "Verifies a data-only task-local receipt; it authorizes no activation."
  @spec verify(receipt :: map()) :: :ok | {:error, term()}
  def verify(%{"schema_version" => 1, "kind" => "task_local_refinement"} = receipt),
    do: Contract.verify_digest(receipt, "sha256")

  def verify(_invalid), do: {:error, :invalid_refinement_receipt}

  defp configuration(plan, opts) do
    baseline = opts[:baseline]
    bindings = opts[:bindings]
    repetitions = Keyword.get(opts, :repetitions, 2)
    count = plan.budget["maximum_candidates"] - 1
    support = Keyword.get(opts, :support_policy, Support.strict())

    with :ok <- Plan.verify(plan),
         :ok <- Support.verify(support),
         :ok <- Profile.validate(baseline),
         true <- Enum.any?(plan.seeds, &(&1["content_sha256"] == Contract.digest(baseline))),
         true <- is_map(bindings) and Enum.all?(@bindings, &digest?(bindings[&1])),
         true <- repetitions in 2..5 and count in 0..8,
         true <- is_map(opts[:original]) and is_map(opts[:allocation]) and is_map(opts[:signal]),
         true <-
           is_function(opts[:assess], 2) and is_function(opts[:propose], 2) and
             is_function(opts[:expose], 1),
         {:ok, runtime} <- Evaluator.runtime_identity(opts),
         true <- runtime == plan.target_interface and digest?(runtime["control_sha256"]),
         true <- runtime["id"] != "lemieux.session-profile/v1" do
      data = %{
        "baseline" => baseline,
        "bindings" => bindings,
        "original" => opts[:original],
        "repetitions" => repetitions,
        "maximum_candidates" => count,
        "verifier" => Keyword.get(opts, :verifier, false),
        "support_policy" => support,
        "allocation" => Contract.json(opts[:allocation]),
        "runtime" => runtime,
        "signal" => opts[:signal],
        "callbacks_sha256" =>
          private_digest(
            Keyword.take(opts, [
              :isolation,
              :assess,
              :propose,
              :expose,
              :token_bound,
              :observe_probe
            ])
          )
      }

      true = byte_size(JSON.encode!(data)) <= 24_576

      {:ok,
       %{
         baseline: baseline,
         bindings: bindings,
         original: opts[:original],
         repetitions: repetitions,
         maximum: count,
         verifier: data["verifier"] == true,
         support: support,
         runtime: runtime,
         digest: Contract.digest(data)
       }}
    else
      _invalid -> {:error, :invalid_refinement_configuration}
    end
  rescue
    _invalid -> {:error, :invalid_refinement_configuration}
  end

  defp execute(plan, key, config, opts) do
    with :ok <- preflight(opts[:isolation], config.bindings),
         {:ready, _} <- Controller.consider(Keyword.fetch!(opts, :controller), opts[:signal]),
         {:ok, result, accounting} <-
           Controller.experiment(
             opts[:controller],
             "refine/" <> key,
             Plan.to_map(plan),
             opts[:allocation],
             fn child ->
               lane(plan, config, Keyword.put(opts, :controller, child))
               |> lane_result(config, opts)
             end
           ) do
      case result do
        {:ok, receipt} -> {:ok, seal(Map.put(receipt, "accounting", accounting))}
        _uncertain -> :in_doubt
      end
    else
      {:noop, receipt} -> {:ok, seal(baseline(config, receipt["reason"]))}
      {:skip, receipt} -> {:ok, seal(baseline(config, receipt["reason"]))}
      {:error, reason} -> {:ok, seal(baseline(config, reason_name(reason)))}
    end
  end

  defp lane(plan, config, opts) do
    with :ok <- live_allowed(opts),
         {:ok, control} <- probes(config.baseline, "control", config, opts),
         :ok <- opts[:expose].(config.bindings),
         {:ok, candidates, artifacts} <- proposals(plan, config, opts) do
      {accepted, rejected} = Edits.admit(plan, config.baseline, candidates, artifacts)

      compose_and_decide(plan, config, opts, control, accepted, rejected)
    end
  end

  defp compose_and_decide(plan, config, opts, control, accepted, rejected) do
    with {:ok, observed} <- candidate_probes(accepted, config, opts) do
      supported =
        Enum.filter(
          observed,
          &Support.supported?(control, &1.evaluations, config.verifier, config.support)
        )

      {profile, kept, conflicts} =
        Edits.compose(config.baseline, supported, Support.experimental?(config.support))

      validate_composition(
        plan,
        profile,
        kept,
        control,
        observed,
        rejected ++ conflicts,
        config,
        opts
      )
    end
  end

  defp validate_composition(plan, profile, kept, control, observed, excluded, config, opts) do
    operator = if kept == [], do: "seed", else: "task_local"

    with :ok <- Profile.validate(profile),
         {:ok, _} <-
           Surface.validate(plan, config.baseline, profile, Contract.encode!(profile), operator) do
      decide(profile, kept, control, observed, excluded, config, opts)
    end
  end

  defp lane_result(result, config, opts) do
    case result do
      {:ok, _} ->
        result

      {:noop, reason} ->
        {:ok, baseline(config, reason)}

      uncertain ->
        if observer = opts[:on_incomplete] do
          :ok = observer.(%{"stage" => "refinement", "cause" => failure_cause(uncertain)})
        end

        :in_doubt
    end
  end

  # Retain diagnostic categories without copying provider error bodies or
  # arbitrary host terms into durable evidence. Checkpoint recovery semantics
  # stay unchanged: an incomplete effect is never replayed automatically.
  defp failure_cause({:error, {:probe_failed, name, attempt, reason}}),
    do: %{"phase" => name, "attempt" => attempt, "reason" => failure_reason(reason)}

  defp failure_cause({:error, reason}), do: %{"reason" => failure_reason(reason)}
  defp failure_cause(_uncertain), do: %{"reason" => "incomplete_execution"}
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_reason), do: "incomplete_execution"

  defp proposals(plan, config, opts) do
    provider = controlled(opts, :proposer)

    context = %{
      plan: plan,
      baseline: config.baseline,
      original: config.original,
      bindings: config.bindings,
      provider_factory: fn -> controlled(opts, :proposer) end
    }

    case opts[:propose].(context, provider) do
      {:ok, candidates, artifacts} when is_list(candidates) and is_map(artifacts) ->
        if length(candidates) <= config.maximum and
             length(candidates) == length(Enum.uniq_by(candidates, &candidate_id/1)),
           do: {:ok, candidates, artifacts},
           else: {:noop, "proposal_bound_exceeded"}

      {:noop, _reason} ->
        {:noop, "no_supported_improvement"}

      _invalid ->
        {:error, :proposal_failed}
    end
  end

  defp candidate_id(%{id: id}), do: id
  defp candidate_id(_invalid), do: nil

  defp candidate_probes(candidates, config, opts) do
    Enum.reduce_while(candidates, {:ok, []}, fn item, {:ok, acc} ->
      case probes(item.profile, item.candidate.id, config, opts) do
        {:ok, evaluations} -> {:cont, {:ok, acc ++ [Map.put(item, :evaluations, evaluations)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp decide(_profile, [], control, observed, excluded, config, _opts),
    do:
      {:ok,
       results(baseline(config, "no_supported_improvement"), control, observed, [], excluded)}

  defp decide(profile, kept, control, observed, excluded, config, opts) do
    case probes(profile, "composition", config, opts) do
      {:ok, composed} ->
        receipt =
          if Support.supported?(control, composed, config.verifier, config.support),
            do:
              baseline(config, "supported_task_local_change")
              |> Map.merge(%{
                "decision" => "proposed",
                "selected_profile" => profile,
                "selected_sha256" => Contract.digest(profile),
                "candidate_ids" => Enum.map(kept, & &1.candidate.id),
                "qualification" => qualification(config)
              }),
            else: baseline(config, "composition_not_supported")

        {:ok, results(receipt, control, observed, composed, excluded)}

      uncertain ->
        uncertain
    end
  end

  defp results(receipt, control, observed, composed, excluded) do
    Map.merge(receipt, %{
      "control" => control,
      "candidates" =>
        Enum.map(observed, fn item ->
          %{
            "id" => item.candidate.id,
            "sha256" => item.digest,
            "manifest_sha256" => item.candidate.sha256,
            "parents" => item.candidate.parents,
            "manifest" => Candidate.to_map(item.candidate),
            "profile" => item.profile,
            "mechanism" => item.candidate.extensions["mechanism"],
            "evaluations" => item.evaluations
          }
        end),
      "composition" => composed,
      "excluded" => excluded
    })
  end

  defp probes(profile, name, config, opts) do
    Enum.reduce_while(1..config.repetitions, {:ok, []}, fn attempt, {:ok, acc} ->
      case probe(profile, name, attempt, config, opts) do
        {:ok, record} -> {:cont, {:ok, acc ++ [record]}}
        error -> {:halt, {:error, {:probe_failed, name, attempt, error}}}
      end
    end)
  end

  defp probe(profile, name, attempt, config, opts) do
    {module, state} = opts[:isolation]
    id = "probe_" <> Lemieux.ID.generate()

    with :ok <- preflight(opts[:isolation], config.bindings),
         {:ok, lease, guardian} <-
           Resource.acquire(
             fn _ -> module.acquire(state, id, config.bindings) end,
             &module.release(state, &1),
             timeout_ms: Keyword.get(opts, :acquisition_timeout_ms, 5000),
             abort: fn -> abort_lease(module, state, id) end
           ) do
      try do
        with true <- lease.id == id,
             :ok <- module.validate(state, lease, config.bindings),
             {:ok, runtime} <-
               Evaluator.runtime(
                 name,
                 profile,
                 controlled(opts, if(name == "composition", do: :composition, else: :probe)),
                 runtime_factory: opts[:runtime_factory],
                 sessions_dir: Keyword.fetch!(opts, :sessions_dir),
                 session: lease.session
               ),
             {:ok, observation} <- Runtime.run(runtime, lease.task),
             :ok <- preflight(opts[:isolation], config.bindings),
             :ok <- module.validate(state, lease, config.bindings),
             {:ok, changes} <- ProfileDelta.changes(config.baseline, profile),
             :ok <- RuntimeEvidence.verify(observation, lease.runtime_identity, changes),
             assessment <- opts[:assess].(observation, lease),
             {:ok, record} <-
               Evidence.record(observation, assessment, config.verifier, lease.runtime_identity),
             :ok <- observe_probe(opts, name, profile, observation, record) do
          {:ok,
           Map.merge(record, %{
             "attempt" => attempt,
             "lease_id" => id,
             "profile_sha256" => Contract.digest(profile)
           })}
        else
          _failed -> {:error, :probe_incomplete}
        end
      after
        :ok = Resource.release(guardian)
      end
    end
  end

  defp observe_probe(opts, name, profile, observation, record) do
    if observer = opts[:observe_probe],
      do:
        observer.(%{
          "phase" => name,
          "profile" => profile,
          "observation" => observation,
          "assessment" => record
        }),
      else: :ok
  end

  defp abort_lease(module, state, id) do
    if function_exported?(module, :abort, 2), do: module.abort(state, id), else: :ok
  end

  defp controlled(opts, role) do
    provider =
      case opts[:provider] do
        factory when is_function(factory, 1) -> factory.(role)
        factory when is_function(factory, 0) -> factory.()
        provider -> provider
      end

    Controller.provider(opts[:controller], role, provider,
      token_bound: opts[:token_bound],
      timeout_ms: Keyword.get(opts, :request_timeout_ms, 5000)
    )
  end

  defp live_allowed(opts) do
    provider =
      case opts[:provider] do
        factory when is_function(factory, 1) -> factory.(:probe)
        factory when is_function(factory, 0) -> factory.()
        provider -> provider
      end

    if Controller.scripted?(provider) or opts[:allow_live] == true,
      do: :ok,
      else: {:error, :live_refinement_requires_allow_live}
  end

  defp baseline(config, reason) do
    %{
      "schema_version" => 1,
      "kind" => "task_local_refinement",
      "decision" => "baseline",
      "reason" => reason,
      "request_sha256" => config.digest,
      "bindings" => config.bindings,
      "original" => config.original,
      "source_runtime" => config.runtime,
      "original_profile_sha256" => Contract.digest(config.baseline),
      "selected_profile" => config.baseline,
      "selected_sha256" => Contract.digest(config.baseline),
      "qualification" => "unassessed",
      "support_policy" => config.support,
      "candidate_ids" => [],
      "control" => [],
      "candidates" => [],
      "composition" => [],
      "excluded" => []
    }
  end

  defp qualification(%{support: %{"id" => id}})
       when id in ~w(experimental_mean/v1 experimental_mean/v2),
       do: "experimental_task_local"

  defp qualification(config),
    do: if(config.verifier, do: "task_local_verified", else: "behavioral_unconfirmed")

  defp seal(receipt),
    do: Map.put(receipt, "sha256", Contract.digest(Map.delete(receipt, "sha256")))

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp private_digest(value),
    do: value |> :erlang.term_to_binary([:deterministic]) |> Contract.sha256()

  defp reason_name(reason), do: Atom.to_string(reason)
end
