defmodule Lemieux.Learning.Promotion do
  @moduledoc """
  **Experimental.** Not part of the stable public API.

  Host-owned automatic guidance through ordinary asset proposals and approvals.
  Retention, task-local use, independently confirmed canaries and reviewed code
  changes remain different operations. Discovery objects never become active.

  The host serializes these transitions through `Promotion.Host`. A transaction
  installs registry, effective harness and audit receipt together or restores the
  prior values on apply/restart failure. The reference in-memory host prepares
  the runtime before an atomic pointer swap; durable or external-runtime hosts
  must journal intent and reconcile interrupted installation before serving work.

  Every operation, including cached use and resume, obtains fresh host authority
  inside the transaction. Stored policy digests are provenance, never grants.
  Call `current/2` before each new or resumed invocation. No scheduler, model
  request or default automatic activation starts here. One unresolved adaptation
  is allowed per scope, avoiding stacks of individually tested but untested
  composed changes. Resolve it before proposing a replacement.
  """
  alias Lemieux.Asset.Proposal
  alias Lemieux.Asset.Registry
  alias Lemieux.Asset.Version
  alias Lemieux.Contract
  alias Lemieux.Harness
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Overlay
  alias Lemieux.Learning.Promotion.Guidance
  alias Lemieux.Learning.Promotion.Policy

  @type host :: {module(), term()}
  @type authority :: (-> {:ok, map()} | {:error, term()})
  @type state :: map()

  @doc "Creates host-owned state over a fresh effective base; no candidate is applied."
  @spec new(base :: Harness.t(), scope :: map()) :: {:ok, state()} | {:error, term()}
  def new(%Harness{} = base, %{"id" => id} = scope) when is_binary(id) and id != "" do
    with {:ok, local} <- baseline(id, :session, :task),
         {:ok, persistent} <- baseline(id, :host, :project),
         {:ok, registry} <- bootstrap(Registry.new(), local),
         {:ok, registry} <- bootstrap(registry, persistent) do
      {:ok,
       %{
         base: base,
         harness: base,
         scope: scope,
         registry: registry,
         baselines: %{"task_local" => local, "canary" => persistent},
         grant: nil,
         activation: nil,
         quarantine: %{},
         receipts: %{},
         history: [],
         revision: 0
       }}
    end
  end

  def new(_base, _scope), do: {:error, :invalid_promotion_base}

  defp baseline(id, layer, scope) do
    Version.new(%{
      type: :prompt,
      layer: layer,
      scope: scope,
      project_id: id,
      content: %{"system_suffix" => "", "tool_descriptions" => %{}}
    })
  end

  defp bootstrap(registry, version) do
    with {:ok, proposal} <-
           Proposal.approve(Proposal.new(version), %{
             "type" => "host",
             "id" => "promotion-baseline"
           }),
         {:ok, registry, _} <- Registry.activate(registry, proposal),
         do: {:ok, registry}
  end

  @doc "Retains a currently applicable lesson under an explicit host policy, without a prompt."
  @spec retain(store :: Lessons.t(), lesson :: Lesson.t(), authority :: authority()) ::
          {:ok, map()} | {:error, term()}
  def retain(store, lesson, authority) do
    with {:ok, context} <- fresh(authority),
         :ok <- Policy.authorize(context, "retain"),
         true <- lesson.scope == context.scope,
         :ok <- Lesson.applicable(lesson, context.lesson_context, context.now),
         :ok <- Lessons.append(store, lesson) do
      {:ok,
       seal(%{
         "action" => "retained",
         "lesson_sha256" => lesson.sha256,
         "actor" => Policy.actor(context.policy),
         "qualification" => lesson.qualification
       })}
    else
      _refused -> {:error, :lesson_retention_not_authorized}
    end
  end

  @doc "Approves and atomically installs eligible text guidance through the host transaction."
  @spec promote(host :: host(), key :: String.t(), request :: map(), authority :: authority()) ::
          term()
  def promote(host, key, request, authority),
    do: transact(host, authority, &prepare(&1, key, request, authority))

  @doc "Rebinds current authority and selects the effective harness, also on session resume."
  @spec current(host :: host(), authority :: authority()) :: term()
  def current(host, authority), do: transact(host, authority, &rebind(&1, authority))

  @doc "Records a selected canary observation; a failed check rolls back and quarantines bytes."
  @spec observe(host :: host(), observation :: map(), authority :: authority()) :: term()
  def observe(host, observation, authority),
    do: transact(host, authority, &observation(&1, observation, authority))

  @doc "Restores the exact known prior registry pointer and effective harness."
  @spec undo(host :: host(), authority :: authority()) :: term()
  def undo(host, authority), do: transact(host, authority, &explicit_undo(&1, authority))

  @doc "Shared, executable, evaluator or privilege changes remain unapproved review proposals."
  @spec review(version :: Version.t()) :: Proposal.t()
  def review(%Version{} = version), do: Proposal.new(version)

  @doc false
  @spec failed(current :: state(), proposed :: state(), receipt :: map()) :: {state(), map()}
  def failed(current, proposed, receipt) do
    digest = proposed.grant["content_sha256"]

    failure =
      seal(
        Map.merge(Map.delete(receipt, "sha256"), %{
          "action" => "quarantined",
          "reason" => "runtime_installation_failed"
        })
      )

    next = %{
      current
      | quarantine: Map.put(current.quarantine, digest, failure),
        history: current.history ++ [failure],
        revision: current.revision + 1
    }

    {next, failure}
  end

  defp transact({module, state}, authority, fun) do
    module.transact(state, fn current -> attach_check(fun.(current), authority) end)
  end

  defp attach_check({:ok, next, harness, receipt}, authority),
    do: {:ok, next, harness, receipt, fn -> commit_authority(next, harness, authority) end}

  defp attach_check(error, _authority), do: error

  defp commit_authority(state, harness, authority) do
    with {:ok, context} <- context(state, authority),
         true <- is_nil(state.grant) or eligible?(state.grant, context),
         true <-
           if(state.grant, do: selected(state, context) == harness, else: state.base == harness) do
      :ok
    else
      _refused -> {:error, :current_host_authority_required}
    end
  end

  defp prepare(state, key, request, authority) do
    with {:ok, context} <- context(state, authority),
         :ok <- Policy.authorize(context, to_string(request.mode)),
         true <- is_binary(key) and byte_size(key) in 1..128,
         true <- map_size(state.receipts) < 64 and length(state.history) < 128 do
      request_sha = Contract.digest(Contract.json(request))

      cached_or_activate(state.receipts[key], state, key, request, request_sha, context)
    else
      _refused -> {:error, :promotion_not_authorized}
    end
  rescue
    _invalid -> {:error, :invalid_promotion_request}
  end

  defp cached_or_activate(nil, state, key, request, request_sha, context),
    do: activate(state, key, request, request_sha, context)

  defp cached_or_activate(
         %{"request_sha256" => request_sha, "version_id" => version_id} = receipt,
         state,
         _key,
         _request,
         request_sha,
         context
       ) do
    if not is_nil(state.grant) and state.grant["version_id"] == version_id and
         eligible?(state.grant, context),
       do: {:ok, state, selected(state, context), receipt},
       else: {:error, :resolved_or_stale_promotion}
  end

  defp cached_or_activate(_receipt, _state, _key, _request, _sha, _context),
    do: {:error, :promotion_request_changed}

  defp activate(%{grant: nil} = state, key, request, request_sha, context) do
    with {:ok, overlay, confirmation} <- Guidance.prepare(request, context, state.base),
         false <- Map.has_key?(state.quarantine, request.refinement["selected_sha256"]),
         {:ok, version} <- version(state, overlay, context, request.mode),
         {:ok, approved} <- Proposal.approve(Proposal.new(version), Policy.actor(context.policy)),
         {:ok, registry, activation} <- Registry.activate(state.registry, approved) do
      grant = grant(request, confirmation, context, version)

      receipt =
        seal(%{
          "action" => "activated",
          "request_sha256" => request_sha,
          "version_id" => version.id,
          "asset_sha256" => version.digest,
          "actor" => approved.approved_by,
          "proposal_id" => approved.id,
          "activation" => Contract.json(activation),
          "grant" => grant
        })

      next = %{
        state
        | registry: registry,
          activation: activation,
          grant: grant,
          harness: record_asset(Guidance.apply(state.base, overlay), version, grant),
          receipts: Map.put(state.receipts, key, receipt),
          history: state.history ++ [receipt],
          revision: state.revision + 1
      }

      {:ok, next, selected(next, context), receipt}
    else
      true -> {:error, :candidate_quarantined}
      {:error, _} = error -> error
    end
  end

  defp activate(_state, _key, _request, _sha, _context),
    do: {:error, :active_adaptation_requires_resolution}

  defp version(state, overlay, context, mode) do
    prior = state.baselines[to_string(mode)]

    Version.new(%{
      type: :prompt,
      layer: prior.layer,
      scope: prior.scope,
      project_id: state.scope["id"],
      parent_id: prior.id,
      rollback_target_id: prior.id,
      content: Overlay.to_map(overlay),
      safety: %{
        "policy_sha256" => context.policy["sha256"],
        "runtime_sha256" => context.runtime_sha256,
        "mode" => to_string(mode),
        "task_id" => if(mode == :task_local, do: context.task_id)
      },
      authored_by: Policy.actor(context.policy)
    })
  end

  defp record_asset(harness, version, grant) do
    asset = %{
      "type" => "automatic_guidance",
      "id" => version.id,
      "sha256" => version.digest,
      "qualification" => grant["qualification"],
      "policy_sha256" => grant["policy_sha256"],
      "refinement_sha256" => grant["refinement_sha256"]
    }

    context =
      Map.update(harness.harness_context || %{}, "resolved_assets", [asset], &(&1 ++ [asset]))

    %{harness | harness_context: context}
  end

  defp grant(request, confirmation, context, version) do
    expires = DateTime.add(context.now, context.policy["ttl_ms"], :millisecond)

    %{
      "version_id" => version.id,
      "content_sha256" => request.refinement["selected_sha256"],
      "refinement_sha256" => request.refinement["sha256"],
      "mode" => to_string(request.mode),
      "policy_sha256" => context.policy["sha256"],
      "scope" => context.scope,
      "bindings" => context.bindings,
      "runtime_sha256" => context.runtime_sha256,
      "task_id" => context.task_id,
      "qualification" =>
        if(confirmation,
          do: "independently_confirmed_canary",
          else: request.refinement["qualification"]
        ),
      "confirmation" => confirmation,
      "description_tools" => Enum.sort(Map.keys(version.content["tool_descriptions"] || %{})),
      "canary" => context.policy["canary"],
      "observations" => [],
      "stage" => if(request.mode == :canary, do: "canary", else: "task_local"),
      "expires_at" => DateTime.to_iso8601(expires)
    }
  end

  defp rebind(state, authority) do
    with {:ok, context} <- context(state, authority) do
      cond do
        is_nil(state.grant) ->
          {:ok, state, state.base, seal(%{"action" => "baseline"})}

        eligible?(state.grant, context) ->
          {:ok, state, selected(state, context), selection_receipt(state, context)}

        true ->
          rollback(state, "authority_or_evidence_expired", context)
      end
    end
  end

  defp eligible?(grant, context) do
    Policy.authorize(context, grant["mode"]) == :ok and
      grant["policy_sha256"] == context.policy["sha256"] and grant["bindings"] == context.bindings and
      grant["runtime_sha256"] == context.runtime_sha256 and
      Guidance.authorized?(grant, context) and
      grant["refinement_sha256"] in context.refinements and
      before?(context.now, grant["expires_at"]) and
      confirmation_current?(grant["confirmation"], context)
  end

  defp confirmation_current?(nil, _context), do: true

  defp confirmation_current?(confirmation, context),
    do:
      confirmation["sha256"] in context.confirmations and
        before?(context.now, confirmation["expires_at"])

  defp selected(state, context),
    do: if(selected?(state.grant, context.task_id), do: state.harness, else: state.base)

  defp selected?(%{"mode" => "task_local", "task_id" => task_id}, task_id), do: true
  defp selected?(%{"mode" => "task_local"}, _task), do: false
  defp selected?(%{"stage" => "active"}, _task), do: true

  defp selected?(grant, task) do
    <<number::unsigned-64, _::binary>> =
      :crypto.hash(:sha256, grant["canary"]["salt"] <> "/" <> task)

    rem(number, 100) < grant["canary"]["percent"]
  end

  defp selection_receipt(state, context),
    do:
      seal(%{
        "action" => "selected",
        "version_id" => state.grant["version_id"],
        "task_id" => context.task_id,
        "selected" => selected?(state.grant, context.task_id),
        "policy_sha256" => context.policy["sha256"],
        "stage" => state.grant["stage"]
      })

  defp observation(state, observation, authority) do
    with {:ok, context} <- context(state, authority),
         true <- not is_nil(state.grant) and state.grant["mode"] == "canary",
         true <- eligible?(state.grant, context),
         true <-
           Enum.sort(Map.keys(observation)) ==
             Enum.sort(~w(id version_id task_id passed regression trace_sha256)),
         true <- observation["version_id"] == state.grant["version_id"],
         true <-
           observation["task_id"] == context.task_id and selected?(state.grant, context.task_id),
         true <- is_binary(observation["id"]) and byte_size(observation["id"]) in 1..128,
         true <- is_boolean(observation["passed"]) and is_boolean(observation["regression"]),
         true <-
           is_binary(observation["trace_sha256"]) and byte_size(observation["trace_sha256"]) == 64 do
      record_observation(state, observation, context)
    else
      _refused -> {:error, :invalid_canary_observation}
    end
  end

  defp record_observation(state, observation, context) do
    prior = Enum.find(state.grant["observations"], &(&1["id"] == observation["id"]))

    cond do
      prior == observation ->
        {:ok, state, selected(state, context), selection_receipt(state, context)}

      not is_nil(prior) ->
        {:error, :canary_observation_changed}

      observation["regression"] or not observation["passed"] ->
        rollback(state, "canary_regression", context, observation)

      length(state.grant["observations"]) >= 32 ->
        {:error, :canary_observation_limit}

      true ->
        successful_observation(state, observation, context)
    end
  end

  defp successful_observation(state, observation, context) do
    observations = state.grant["observations"] ++ [observation]

    stage =
      if length(Enum.uniq_by(observations, & &1["task_id"])) >=
           state.grant["canary"]["minimum_observations"],
         do: "active",
         else: "canary"

    grant = state.grant |> Map.put("observations", observations) |> Map.put("stage", stage)

    receipt =
      seal(%{
        "action" => "canary_observed",
        "observation" => observation,
        "stage" => stage,
        "actor" => Policy.actor(context.policy)
      })

    next = %{
      state
      | grant: grant,
        history: state.history ++ [receipt],
        revision: state.revision + 1
    }

    {:ok, next, selected(next, context), receipt}
  end

  defp explicit_undo(state, authority) do
    with {:ok, context} <- context(state, authority) do
      if state.grant,
        do: rollback(state, "explicit_undo", context),
        else: {:ok, state, state.base, seal(%{"action" => "baseline"})}
    end
  end

  defp rollback(state, reason, context, observation \\ nil) do
    with {:ok, registry, activation} <-
           Registry.rollback(
             state.registry,
             state.activation,
             state.baselines[state.grant["mode"]]
           ) do
      receipt =
        seal(%{
          "action" => "rolled_back",
          "reason" => reason,
          "version_id" => state.grant["version_id"],
          "actor" => Policy.actor(context.policy),
          "activation" => Contract.json(activation),
          "observation" => observation
        })

      next = %{
        state
        | registry: registry,
          grant: nil,
          activation: nil,
          harness: state.base,
          quarantine: Map.put(state.quarantine, state.grant["content_sha256"], receipt),
          history: state.history ++ [receipt],
          revision: state.revision + 1
      }

      {:ok, next, state.base, receipt}
    end
  end

  defp context(state, authority) do
    with {:ok, context} <- fresh(authority),
         true <- context.scope == state.scope and context.base == state.base,
         true <- is_binary(context.task_id) and byte_size(context.task_id) in 1..256,
         %DateTime{} <- context.now do
      {:ok, context}
    else
      _refused -> {:error, :current_host_authority_required}
    end
  rescue
    _invalid -> {:error, :current_host_authority_required}
  end

  defp fresh(authority) do
    authority.()
  rescue
    _unavailable -> {:error, :current_host_authority_required}
  catch
    _kind, _unavailable -> {:error, :current_host_authority_required}
  end

  defp before?(now, encoded) do
    case DateTime.from_iso8601(encoded) do
      {:ok, expires, 0} -> DateTime.compare(now, expires) == :lt
      _invalid -> false
    end
  end

  defp seal(map), do: Map.put(map, "sha256", Contract.digest(map))
end
