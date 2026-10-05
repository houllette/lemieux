defmodule Lemieux.Session.Audit do
  @moduledoc false

  require Logger

  alias Lemieux.Contract
  alias Lemieux.Environment
  alias Lemieux.Evidence.Run, as: RunEvidence
  alias Lemieux.Harness.Snapshot, as: HarnessSnapshot
  alias Lemieux.Hooks
  alias Lemieux.Request
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Requests
  alias Lemieux.Tool.Profile

  def request_snapshot_opts(state, extra) do
    harness = state.evidence.current_harness_snapshot

    Keyword.merge(
      [
        kind: request_kind(state),
        catalog: Catalog.tool_catalog(state),
        tool_profile: Profile.snapshot(state.tool_profile),
        token_counter: state.tool_token_counter,
        harness_snapshot_id: harness && harness.id,
        harness_snapshot_sha256: harness && harness.semantic_sha256,
        evidence: state.evidence.level
      ],
      extra
    )
  end

  def evidence_level_option(opts) do
    case Keyword.get(opts, :evidence, :full) do
      level when level in [:full, :digests, :off] ->
        level

      other ->
        raise ArgumentError, ":evidence must be :full, :digests or :off, got: #{inspect(other)}"
    end
  end

  def prepare_harness_snapshot(state, request) do
    state = remember_pending_request(state, request)
    context = state.evidence.harness_context
    correlations = current_correlations(state)

    snapshot =
      HarnessSnapshot.build(request,
        resolved_assets: Map.get(context, "resolved_assets", []),
        context_limits: %{
          "context_window" => state.context_window,
          "max_turns" => state.max_turns,
          "max_requests" => state.max_requests,
          "max_cost_usd" => state.max_cost_usd,
          "tool_timeout_ms" => state.tool_timeout_ms,
          "tool_output_bytes" => state.tool_output_bytes
        },
        tool_profile: Profile.snapshot(state.tool_profile),
        hooks: Map.get(context, "hooks", %{"configured" => state.hooks != []}),
        workflow: Map.get(context, "workflow", %{}),
        compaction: %{
          "auto_compaction" => state.compaction.auto_compaction?,
          "compact_at" => state.compaction.compact_at,
          "keep" => state.compaction.keep,
          "keep_attachments" => Contract.json(state.compaction.keep_attachments),
          "summary_sections" => state.compaction.summary_sections
        },
        # The module, never its state: a container handle or a remote
        # workspace's credentials may live in the state, and the snapshot is
        # what says which environment was in force. The host's own map goes
        # over it, so a host that describes its sandbox more fully still can.
        environment_context:
          Map.merge(
            %{"module" => Environment.name(state.environment)},
            Map.get(context, "environment_context", %{})
          ),
        sandbox_profile: Map.get(context, "sandbox_profile", %{}),
        correlations: correlations,
        extensions: Map.get(context, "extensions", %{})
      )

    record_harness_snapshot(state, snapshot)
  end

  # A long tool loop sends many requests under one unchanged harness, and each
  # used to write its own copy of the tool descriptors — a quarter of a real
  # transcript. The run's snapshot stands for every request it describes, so
  # an identical one is not written again: same behavior digest, same
  # correlations. The run resets it, so every prompt still records the harness
  # it ran under, and the request snapshots name the one in force.
  defp record_harness_snapshot(state, snapshot) do
    cond do
      unchanged_harness?(state.evidence.current_harness_snapshot, snapshot) ->
        state

      # Kept in memory, because request snapshots name it, but not written.
      state.evidence.level == :off ->
        Core.put_evidence(state, :current_harness_snapshot, snapshot)

      true ->
        state
        |> Core.put_evidence(:current_harness_snapshot, snapshot)
        |> Core.append({:harness_snapshot, HarnessSnapshot.to_map(snapshot), nil})
        |> Core.emit({:harness_snapshot, snapshot})
    end
  end

  defp unchanged_harness?(
         %HarnessSnapshot{semantic_sha256: digest, correlations: correlations},
         %HarnessSnapshot{semantic_sha256: digest, correlations: correlations}
       ),
       do: true

  defp unchanged_harness?(_current, _snapshot), do: false

  defp current_correlations(%{evidence: %{current_run: %{correlations: correlations}}}),
    do: correlations

  defp current_correlations(state), do: state.evidence.correlation_ids

  def remember_pending_request(%{evidence: %{current_run: run}} = state, %Request{} = request)
      when is_map(run),
      do: Core.put_evidence(state, :current_run, Map.put(run, :pending_request, request))

  def remember_pending_request(state, %Request{}), do: state

  def note_request_hook_outcome(
        %{evidence: %{current_run: %{pending_request: %Request{} = original} = run}} = state,
        %Request{} = effective
      ) do
    ordinal = run.request_ordinal + 1
    changed_fields = changed_request_fields(original, effective)

    outcome = %{
      "stage" => "prepare_next_turn",
      "request_ordinal" => ordinal,
      "outcome" => if(changed_fields == [], do: "allowed", else: "rewritten"),
      "changed_fields" => changed_fields
    }

    outcomes =
      if Hooks.registered?(state.hooks, :prepare_next_turn),
        do: run.hook_outcomes ++ [outcome],
        else: run.hook_outcomes

    Core.put_evidence(state, :current_run, %{
      run
      | request_ordinal: ordinal,
        hook_outcomes: outcomes
    })
  end

  def note_request_hook_outcome(state, %Request{}), do: state

  def note_request_hook_failure(%{evidence: %{current_run: run}} = state, reason)
      when is_map(run) do
    outcome = %{
      "stage" => "prepare_next_turn",
      "request_ordinal" => run.request_ordinal + 1,
      "outcome" => hook_failure_outcome(reason),
      "changed_fields" => []
    }

    Core.put_evidence(state, :current_run, %{run | hook_outcomes: run.hook_outcomes ++ [outcome]})
  end

  def note_request_hook_failure(state, _reason), do: state

  defp hook_failure_outcome({:denied, _reason}), do: "denied"
  defp hook_failure_outcome(_reason), do: "failed"

  defp changed_request_fields(original, effective) do
    ~w(model system entries tools params output_schema)a
    |> Enum.filter(&(Map.fetch!(original, &1) != Map.fetch!(effective, &1)))
    |> Enum.map(&Atom.to_string/1)
  end

  # The kind an aside asked to be recorded under; `:turn` for everything the
  # loop starts on its own. Compaction passes its own.
  defp request_kind(%{aside: %Aside{kind: kind}}), do: kind
  defp request_kind(_state), do: :turn

  def finalize_run(%{evidence: %{current_run: nil}} = state, _stop_reason),
    do: %{state | aside: nil}

  # At `:off` a run leaves no manifest; it only ends.
  def finalize_run(%{evidence: %{level: :off}} = state, _stop_reason),
    do: state |> Core.put_evidence(:current_run, nil) |> Map.put(:aside, nil)

  def finalize_run(state, stop_reason) do
    state = ensure_harness_snapshot(state)
    run = state.evidence.current_run
    run_entries = state |> Core.entries() |> Enum.drop(run.start_seq)
    latency_ms = max(System.monotonic_time(:millisecond) - run.started_at, 0)

    attrs = %{
      id: run.id,
      model: state.model,
      stop_reason: stop_reason,
      correlations: run.correlations,
      scope: Map.take(run.correlations, ~w(tenant_id project_id task_id)),
      harness_snapshot: state.evidence.current_harness_snapshot,
      artifacts: state.evidence.evidence_artifacts,
      hook_outcomes: run.hook_outcomes,
      latency_ms: latency_ms,
      sandbox_completeness:
        Map.get(state.evidence.harness_context, "sandbox_completeness", "unknown")
    }

    case RunEvidence.from_entries(run_entries, attrs) do
      {:ok, evidence} ->
        state
        |> Core.put_evidence(:last_run_evidence, evidence)
        |> Core.put_evidence(:current_run, nil)
        |> Map.put(:aside, nil)
        |> Core.append({:run_evidence, RunEvidence.to_map(evidence), nil})
        |> Core.emit({:run_evidence, evidence})

      # The work is done by now; only its record failed. Raising here crashed a
      # session that had just finished a prompt successfully, taking whatever
      # the person was about to ask next with it. The failure is logged,
      # announced, and recorded as a degraded manifest in the manifest's place,
      # which also keeps the next run's id from repeating this one's.
      {:error, reason} ->
        Logger.warning(
          "lemieux: could not build terminal run evidence for session #{state.id}: " <>
            inspect(reason)
        )

        state
        |> Core.put_evidence(:current_run, nil)
        |> Map.put(:aside, nil)
        |> Core.append(
          {:run_evidence,
           %{
             "degraded" => true,
             "run_id" => run.id,
             "stop_reason" =>
               stop_reason |> Instrumentation.telemetry_stop_reason() |> Atom.to_string(),
             "reason" => inspect(reason)
           }, nil}
        )
        |> Core.emit({:run_evidence_failed, %{run_id: run.id, reason: reason}})
    end
  end

  def ensure_harness_snapshot(%{evidence: %{current_run: nil}} = state), do: state

  def ensure_harness_snapshot(
        %{evidence: %{current_harness_snapshot: %HarnessSnapshot{}}} = state
      ),
      do: state

  def ensure_harness_snapshot(
        %{evidence: %{current_run: %{pending_request: %Request{} = request}}} = state
      ),
      do: prepare_harness_snapshot(state, request)

  def ensure_harness_snapshot(state),
    do: prepare_harness_snapshot(state, fallback_request(state))

  defp fallback_request(state) do
    entries = Core.behavior_entries(state)

    %Request{
      model: state.model,
      system: Compacting.with_summary(state, entries),
      entries: Compacting.sendable(state, entries, Requests.request_opts(state)),
      tools: state.tools,
      params: state.params,
      output_schema: state.output_schema
    }
  end
end
