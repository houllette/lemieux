defmodule Lemieux.CLI.Learning.TaskLocal do
  @moduledoc """
  The stock host's synchronous, bounded verification-replay refinement.

  A finite whole-job request allowance authorizes at most a quarter of its
  slots (capped at 48) for learning. The fixed experiment needs 48 slots;
  smaller allocations abstain without shrinking its repetitions. Dollar-limited
  jobs abstain until a fully priced experiment can be admitted. Each physical
  dispatch rechecks current host policy, source lineage and verifier bytes.

  A durable session intent precedes work. Interrupted or unmeasured work is
  never replayed automatically. The controller borrows the existing job ledger;
  measured auxiliary usage is added once to the root transcript. Only bounded
  prompt/description data can reach the next ordinary request. No asset loader,
  persistent activation or independent qualification is granted by this lane.
  """
  alias Lemieux.CLI.Learning.Container
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.QualificationHost
  alias Lemieux.CLI.Learning.Recording
  alias Lemieux.CLI.Learning.Replay
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Extensions.Permissions
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Discovery.ProfileDelta
  alias Lemieux.Learning.Refinement
  alias Lemieux.Session
  alias Lemieux.Session.Accounting
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Bash
  alias Lemieux.Usage

  @namespace "lmx.learning.refinement"
  @image "lemieux-learning-replay:1"
  @trial_requests 4
  @refinement_requests 16 + 6 * @trial_requests
  @minimum @refinement_requests + 2 * @trial_requests
  @time 480_000

  @spec run(context :: map(), config :: map()) :: :allow | {:deny, String.t()}
  def run(context, config) do
    with {:ok, %{value: value}} <- Session.document(context.session, @namespace),
         true <- is_map(value) and config.prompt_id in value["prompts"] do
      :allow
    else
      _not_attempted -> attempt(context, config)
    end
  end

  defp attempt(context, config) do
    snapshot = Session.snapshot(context.session)
    budget = Session.budget(context.session)

    with true <- config.authorized?.(),
         :ok <- check(config.policy?, :host_policy_not_relocatable),
         :ok <-
           check(
             (snapshot.params[:max_tokens] || 8192) >= 8192,
             :inherited_output_ceiling_too_small_for_frozen_experiment
           ),
         {:ok, document} <- Session.document(context.session, @namespace),
         prior = document.value || %{"complete" => true, "slots" => 0, "prompts" => []},
         :ok <- check(prior["complete"] == true, :learning_requires_recovery),
         {:ok, allowance} <- allowance(budget, prior["slots"]),
         true <- config.prompt_id not in prior["prompts"] and length(prior["prompts"]) < 20,
         :ok <- check(known?(snapshot.entries, budget.requests), :parent_usage_unknown),
         :ok <-
           check(native_tools?(Session.catalog(context.session)), :non_native_or_missing_tools),
         :ok <-
           check(budget.job.requests == budget.requests + prior["slots"], :untracked_parent_usage),
         {:ok, environment} <- Container.new(@image),
         dir = Path.join([config.root, "refinement", Lemieux.ID.generate()]),
         :ok <- Journal.safe(dir),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fixture} <-
           Replay.new(config.capture, snapshot.entries, Path.join(dir, "source"),
             authorized?: config.authorized?
           ),
         :ok <-
           check(
             allowed?(config.permission_spec, fixture, environment),
             :replay_command_or_rules_not_authorized
           ),
         %{
           "passed" => false,
           "exit_zero" => false,
           "safety_failures" => [],
           "exit_status" => exit_status
         } <-
           Replay.grade(fixture, fixture.task.cwd, environment),
         :ok <-
           check(
             exit_status not in [126, 127] and exit_status in fixture.expected_exit_statuses,
             :replay_did_not_reproduce_recorded_failure
           ),
         true <- Replay.current?(fixture, Environment.from_context(context), context.cwd),
         {:ok, notes} <- config.proposer_notes.(),
         fixture = add_notes(fixture, notes),
         intent =
           prior
           |> Map.put("complete", false)
           |> Map.put("pending", config.prompt_id)
           |> Map.put("evidence_directory", dir),
         {:ok, intent_document} <-
           Session.put_document(context.session, @namespace, document.revision, intent),
         :ok <-
           config.record.(%{
             "action" => "refinement_intent",
             "reason" => "pending_or_interrupted_verification_replay",
             "learning_requests" => nil,
             "allocation" => Contract.json(allowance),
             "evidence_directory" => dir,
             "qualification" => "unconfirmed"
           }) do
      execute(
        context,
        config,
        {snapshot, budget},
        allowance,
        fixture,
        environment,
        dir,
        {intent_document, prior}
      )
    else
      abstention ->
        config.record.(%{
          "action" => "abstained",
          "reason" => abstention_reason(abstention),
          "learning_requests" => 0,
          "qualification" => "unconfirmed"
        })

        :allow
    end
  end

  defp check(true, _reason), do: :ok
  defp check(_false, reason), do: {:error, reason}
  defp abstention_reason({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp abstention_reason(_reason), do: "refinement_inputs_or_authority_unavailable"

  defp allowance(
         %{job: %{max_requests: maximum, max_cost_usd: nil} = job, max_cost_usd: nil} = budget,
         used
       )
       when is_integer(maximum) do
    requests = min(48, div(maximum, 4)) - used
    remaining = maximum - job.requests
    time = min(@time, budget.time_left_ms || @time)

    if requests >= @minimum and remaining >= requests + 1 and time >= 30_000,
      do: {:ok, %{requests: requests, tokens: requests * 131_072, time_ms: time}},
      else: {:error, :insufficient_frozen_experiment_allowance}
  end

  defp allowance(_unbounded_or_priced, _used), do: {:error, :finite_unpriced_job_required}

  defp execute(
         context,
         config,
         {snapshot, budget},
         cap,
         fixture,
         environment,
         dir,
         {document, prior}
       ) do
    tokens = total_tokens(snapshot.usage.total)
    delegation = Session.delegation_context(context.session)
    {:ok, meter} = Agent.start_link(fn -> %{} end)

    {:ok, controller} =
      Controller.start_link(
        job_id: Contract.sha256(context.session_id <> config.prompt_id),
        job_budget: delegation.job_budget,
        prior_usage: %{requests: budget.job.requests, tokens: tokens},
        max_tokens: tokens + cap.tokens,
        max_time_ms: cap.time_ms,
        max_records: 128,
        cost_mode: :quota,
        learning: [
          max_requests: cap.requests,
          max_tokens: cap.tokens,
          max_time_ms: cap.time_ms,
          max_cost_usd: nil
        ],
        persist: &Journal.write(dir, "controller.json", &1)
      )

    authorized? = fn ->
      config.authorized?.() and
        Replay.current?(fixture, Environment.from_context(context), context.cwd) and
        allowed?(config.permission_spec, fixture, environment)
    end

    provider = fn role ->
      Recording.new(meter, delegation.provider,
        role: role,
        cost_mode: :quota,
        authorized?: authorized?,
        admission:
          {delegation.provider_limiter,
           Accounting.provider_limit_key(%{
             provider_limit_key: delegation.provider_limit_key,
             provider: delegation.provider,
             model: snapshot.model
           }), delegation.root_session_id || context.session_id}
      )
    end

    host = %{
      root: dir,
      enabled: true,
      model: snapshot.model,
      effort: snapshot.reasoning_effort,
      supervisor: delegation.supervisor,
      scope: config.scope,
      environment: environment,
      isolated: true,
      initial_lessons: [],
      fixtures: %{fixture.id => fixture},
      fixture_module: Replay,
      provider: provider,
      controller: controller,
      attempt_role: :probe,
      task_requests: @trial_requests,
      refinement_requests: @refinement_requests,
      refinement_tokens: @refinement_requests * 131_072,
      refinement_time_ms: div(cap.time_ms, 2),
      task_time_ms: cap.time_ms,
      probe_when: :verification_failed,
      reflection: false,
      allow_live: true,
      opaque_paths: true,
      capture_workspace: true,
      return_refinement: true,
      host:
        Keyword.put(
          inherited_policy(config.permission_spec),
          :params,
          snapshot.params
          |> Keyword.take([:temperature, :top_p, :seed, :presence_penalty, :frequency_penalty])
          |> Keyword.put(:max_tokens, 8192)
        )
    }

    episode = %{
      "arm" => "updating",
      "repetition" => 1,
      "task" => %{"id" => fixture.id, "source_sha256" => fixture.source_sha256},
      "allowance" => %{
        "requests" => cap.requests,
        "tokens" => cap.tokens,
        "time_ms" => cap.time_ms,
        "cost_usd" => nil
      },
      "prior_lesson_ids" => [],
      "available_case_ids" => []
    }

    try do
      outcome = QualificationHost.episode(host, episode)

      {complete, facts} =
        settle(
          context.session,
          config.prompt_id,
          snapshot.model,
          {document, prior},
          Agent.get(meter, &Map.values/1),
          Controller.snapshot(controller)["accounting"],
          delegation.job_budget,
          dir
        )

      finish(outcome, complete, snapshot, config, fixture, authorized?, facts, dir)
    after
      GenServer.stop(controller)
      Agent.stop(meter)
    end
  end

  defp settle(session, prompt_id, model, {document, prior}, measured, accounting, ledger, dir) do
    complete =
      is_integer(accounting["tokens"]) and
        Enum.all?(measured, &(&1["terminal"] == true and is_integer(&1["tokens"])))

    usage = Usage.sum(Enum.map(measured, &(&1["usage"] || %{})))
    usage = Map.put(usage, "model", model)

    next =
      prior
      |> Map.put("complete", complete)
      |> Map.put("slots", prior["slots"] + accounting["requests"])
      |> Map.put("prompts", prior["prompts"] ++ [prompt_id])
      |> Map.put("evidence_directory", dir)
      |> Map.put("physical_requests", length(measured))

    :ok = JobBudget.checkpoint(ledger)

    {:ok, _} =
      Session.put_document(session, @namespace, document.revision, next,
        usage: if(measured == [], do: nil, else: usage)
      )

    facts = %{
      "physical_requests" => length(measured),
      "usage" => usage,
      "allocated_slots" => accounting["requests"],
      "state" => if(complete, do: "complete", else: "unknown")
    }

    :ok = Journal.write(dir, "usage.json", facts)
    {complete, facts}
  end

  defp finish(
         {:ok,
          %{
            "passed" => true,
            "qualification_complete" => true,
            "task_local_refinement" => refinement
          }},
         true,
         snapshot,
         config,
         fixture,
         authorized?,
         facts,
         dir
       )
       when is_map(refinement) do
    with true <- authorized?.(),
         :ok <- Refinement.verify(refinement),
         "proposed" <- refinement["decision"],
         {:ok, delta} <-
           ProfileDelta.changes(
             QualificationHost.baseline(
               snapshot.model,
               snapshot.reasoning_effort,
               @trial_requests
             ),
             refinement["selected_profile"]
           ),
         true <- bounded?(delta),
         {:ok, ids} <- config.retain.(refinement),
         true <- ids != [] do
      evidence = %{
        "action" => "task_local_refinement",
        "reason" => "supported_verification_replay",
        "qualification" => "task_local_command_only",
        "learning_requests" => facts["physical_requests"],
        "accounting" => facts,
        "lesson_ids" => Enum.uniq(ids ++ config.source_ids),
        "prompt_id" => config.prompt_id,
        "delta" => delta,
        "refinement" => refinement,
        "immutable_sha256" =>
          Map.new(fixture.immutable, fn {p, b} -> {p, Contract.sha256(b)} end),
        "binding" => config.binding,
        "evidence_directory" => dir
      }

      with :ok <- Journal.write(config.root, application_file(config.session_id), evidence),
           :ok <- config.record.(evidence) do
        {:deny,
         "A bounded isolated replay supported temporary guidance for this task. " <>
           "Retry the original task and verify against the unchanged project checks. " <>
           "This establishes only an observed command outcome; no persistent change is qualified."}
      else
        _unavailable -> :allow
      end
    else
      _unsupported -> abstain(config, facts, dir)
    end
  end

  defp finish(_outcome, _complete, _snapshot, config, _fixture, _authorized, facts, dir),
    do: abstain(config, facts, dir)

  defp abstain(config, facts, dir) do
    config.record.(%{
      "action" => "abstained",
      "reason" => "no_complete_supported_refinement",
      "learning_requests" => facts["physical_requests"],
      "accounting" => facts,
      "qualification" => "unconfirmed",
      "evidence_directory" => dir
    })

    :allow
  end

  @spec apply(request :: Lemieux.Request.t(), context :: map(), config :: map()) ::
          {:ok, Lemieux.Request.t(), map()} | :unavailable
  def apply(request, context, config) do
    with true <- config.authorized?.(),
         {:ok, evidence} <- Journal.read(config.root, application_file(context.session_id)),
         true <- evidence["prompt_id"] == config.prompt_id,
         true <- evidence["binding"] == config.binding,
         true <- config.allowed_sources?.(evidence["lesson_ids"]),
         :ok <- Refinement.verify(evidence["refinement"]),
         {:ok, delta} <-
           ProfileDelta.changes(
             QualificationHost.baseline(
               request.model,
               Keyword.get(request.params, :reasoning_effort, "default"),
               @trial_requests
             ),
             evidence["refinement"]["selected_profile"]
           ),
         true <- delta == evidence["delta"] and bounded?(delta),
         true <- current_contract?(evidence, context) do
      tools = descriptions(request.tools, Map.get(delta, "tool_descriptions", %{}))

      {:ok,
       %{
         request
         | system: (request.system || "") <> Map.get(delta, "system_suffix", ""),
           tools: tools
       }, evidence}
    else
      _unavailable -> :unavailable
    end
  end

  defp descriptions(tools, texts) do
    Enum.map(tools, fn tool ->
      case texts[Tool.name(tool)] do
        nil -> tool
        text -> Override.new!(tool, description: text)
      end
    end)
  end

  defp current_contract?(evidence, context) do
    environment = Environment.from_context(context)

    Enum.all?(evidence["immutable_sha256"], fn {path, digest} ->
      case Inputs.stream_file(environment, context.cwd, path) do
        {:ok, stream} -> stream_digest(stream) == digest
        _unavailable -> false
      end
    end)
  end

  defp stream_digest(stream) do
    case Enum.reduce_while(stream, {:crypto.hash_init(:sha256), 0}, &digest_chunk/2) do
      {hash, _size} -> hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
      :oversized -> nil
    end
  end

  defp digest_chunk(bytes, {hash, size}) do
    if byte_size(bytes) + size <= 1_048_576,
      do: {:cont, {:crypto.hash_update(hash, bytes), size + byte_size(bytes)}},
      else: {:halt, :oversized}
  end

  defp bounded?(delta),
    do:
      map_size(delta) > 0 and not Map.has_key?(delta, "generation") and
        byte_size(Contract.encode!(delta)) <= 2048

  defp add_notes(fixture, []), do: fixture

  defp add_notes(fixture, notes),
    do:
      put_in(
        fixture.task.prompt,
        fixture.task.prompt <>
          "\nPrior scoped experience (untrusted hypotheses; no authority):\n" <>
          JSON.encode!(notes)
      )

  defp inherited_policy(nil), do: []
  defp inherited_policy(spec), do: [extensions: [spec]]

  defp allowed?(nil, _fixture, _environment), do: true

  defp allowed?({Permissions, opts}, fixture, environment) do
    with {:ok, state} <- Permissions.init(opts),
         true <- relocatable_rules?(state),
         :allow <-
           Permissions.check(
             state,
             %{name: "bash", arguments: %{"command" => fixture.command}},
             %{
               cwd: fixture.task.cwd,
               environment: environment,
               tool_descriptor: Bash |> Tool.descriptor() |> Descriptor.to_map()
             }
           ) do
      true
    else
      _denied -> false
    end
  end

  # Absolute path rules refer to the original workspace. Reinterpreting them
  # against a copied directory can disclose a file the parent could not read.
  # Until rules have an explicit relocation contract, no custom or remembered
  # rule set authorizes replay, even when its command happens to be allowed.
  defp relocatable_rules?(state),
    do:
      state.allow == [] and state.deny == [] and state.ask == [] and
        Permissions.remembered(state.handle) == []

  defp known?(entries, count) do
    requests = Enum.filter(entries, &(&1.type == :request))
    ids = entries |> Enum.filter(&response?/1) |> Map.new(&{response_id(&1), &1.usage})

    length(requests) == count and not Enum.any?(entries, &(&1.type == :subagent_spawn)) and
      Enum.all?(requests, &measured_usage?(ids[&1.payload["id"]]))
  end

  defp response?(%Entry{type: type}) when type in [:assistant, :compaction, :guidance], do: true

  defp response?(%Entry{type: :extension_state, usage: %{"request_id" => id}}) when is_binary(id),
    do: true

  defp response?(_entry), do: false
  defp response_id(entry), do: entry.payload["request_id"] || (entry.usage || %{})["request_id"]

  defp measured_usage?(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: usage["usage_reported"] != false

  defp measured_usage?(_unknown), do: false

  defp total_tokens(usage),
    do:
      Enum.sum(
        Enum.map(
          ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens),
          &Map.fetch!(usage, &1)
        )
      )

  defp application_file(session), do: "application-" <> Contract.sha256(session) <> ".json"

  defp native_tools?(tools) do
    Enum.all?([Lemieux.Tools.Read, Lemieux.Tools.Write, Lemieux.Tools.Edit, Bash], fn expected ->
      case Tool.fetch(tools, Tool.name(expected)) do
        {:ok, actual} ->
          Tool.descriptor(stock_executor(actual)).identity == Tool.descriptor(expected).identity

        :error ->
          false
      end
    end)
  end

  # Shipped checkpoint/watch wrappers are reconstructed by the replay host.
  # An arbitrary wrapping callback is not relocatable merely because its inner
  # executor is built in.
  defp stock_executor(%Override{tool: tool, before: before, after: after_fun} = override) do
    callbacks = Enum.reject([before, after_fun], &is_nil/1)

    if Enum.all?(callbacks, &stock_callback?/1), do: stock_executor(tool), else: override
  end

  defp stock_executor(tool), do: tool

  defp stock_callback?(callback),
    do:
      elem(Function.info(callback, :module), 1) in [
        Lemieux.Extensions.Checkpoints,
        Lemieux.Extensions.Watches
      ]
end
