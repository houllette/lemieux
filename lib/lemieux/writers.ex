defmodule Lemieux.Writers do
  @moduledoc """
  Opt-in coordination of isolated top-level implementation sessions.

  This does not broaden `Lemieux.Subagent`'s read-only contract. Hosts approve
  non-overlapping briefs, supply environments and a factory with explicit tools
  and current policy, and review immutable artifacts before one coordinator
  integrates them. Nothing is enabled by adding the dependency or starting lmx.

  The parent must already carry one `Lemieux.JobBudget` allowance. Each writer
  uses that exact ledger, execution journal, transcript store and provider rate
  domain even when its provider differs. Writer identity is top-level; its
  workspace, scope and permissions are supplied afresh, never restored as
  authority from a transcript. A stopped attempt is not automatically retried.

  `start/3` returns a capability for observation. Mutating operations require
  current host authorization. Cancellation and parent loss stop writers and
  release their leases; completed patches and full findings remain reviewable.
  Wider adoption still requires matched quality/cost evaluation with real models.
  """
  use GenServer, restart: :temporary
  alias Lemieux.Clock
  alias Lemieux.JobBudget
  alias Lemieux.Session
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tool
  alias Lemieux.Writers.Artifact
  alias Lemieux.Writers.Custody
  alias Lemieux.Writers.Plan
  alias Lemieux.Writers.Scoped
  alias Lemieux.Writers.Workspace
  alias Lemieux.Writers.Worktree

  defmodule Ref do
    @moduledoc "A live observation capability. It carries no integration authority."
    @enforce_keys [:pid, :token, :id]
    defstruct [:pid, :token, :id]
    @type t :: %__MODULE__{pid: pid(), token: reference(), id: String.t()}
  end

  @doc """
  Starts at most four writers under the parent's mounted runtime.

  Required options: `:workspace` implementing `Workspace`, `:factory`
  (`plan, workspace -> {:ok, session_options}`), `:verify`
  (`workspace, plan, result -> {:ok, evidence}`), `:checks` for integration,
  `:authorize` (`action, context, authority -> :ok | {:error, reason}`) and
  `:authority`. Evidence must contain `"status" => "passed"` and identify the
  check. `:timeout_ms` defaults to an hour and is clamped to the parent's
  remaining deadline. Callbacks run outside the parent session process.
  """
  @spec start(parent :: Session.session(), plans :: [Plan.t()], opts :: keyword()) ::
          {:ok, Ref.t()} | {:error, term()}
  def start(parent, plans, opts) do
    with :ok <- validate(plans, opts),
         parent when is_pid(parent) <- GenServer.whereis(parent),
         context = Session.delegation_context(parent),
         :ok <- top_level(context),
         true <- is_pid(context.job_budget) and Process.alive?(context.job_budget),
         :ok <-
           opts[:authorize].(:start, %{parent_id: context.id, plans: plans}, opts[:authority]) do
      timeout = timeout(parent, opts)

      DynamicSupervisor.start_child(
        Sup.subagent_group_supervisor(context.supervisor),
        {__MODULE__,
         Keyword.merge(opts, parent: parent, context: context, plans: plans, timeout_ms: timeout)}
      )
      |> case do
        {:ok, pid} -> GenServer.call(pid, :ref)
        error -> error
      end
    else
      false -> {:error, :shared_allowance_required}
      nil -> {:error, :parent_down}
      error -> error
    end
  end

  @doc "Waits for reviewable results; a caller timeout does not cancel writers."
  @spec await(ref :: Ref.t(), timeout :: timeout()) :: {:ok, map()} | {:error, term()}
  def await(ref, timeout \\ :infinity) do
    GenServer.call(ref.pid, {:await, ref.token}, timeout)
  catch
    :exit, {:timeout, _call} ->
      GenServer.cast(ref.pid, {:withdraw_await, ref.token, self()})
      {:error, :timeout}

    :exit, _gone ->
      {:error, :not_running}
  end

  @doc "Returns current writer identities, statuses, artifacts and inclusive accounting."
  @spec snapshot(ref :: Ref.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(ref), do: GenServer.call(ref.pid, {:snapshot, ref.token})

  @doc "Cancels the batch using current authority, preserving completed artifacts."
  @spec cancel(ref :: Ref.t(), authority :: term()) :: :ok | {:error, term()}
  def cancel(ref, authority),
    do: GenServer.call(ref.pid, {:cancel, ref.token, authority}, :infinity)

  @doc "Integrates only explicitly accepted artifact digests, with fresh authorization and checks."
  @spec integrate(ref :: Ref.t(), digests :: [String.t()], authority :: term()) ::
          {:ok, map()} | {:error, term()}
  def integrate(ref, digests, authority),
    do: GenServer.call(ref.pid, {:integrate, ref.token, digests, authority}, :infinity)

  @doc "Releases the live coordinator; durable transcripts and patch files remain."
  @spec close(ref :: Ref.t(), authority :: term()) :: :ok | {:error, term()}
  def close(ref, authority),
    do: GenServer.call(ref.pid, {:close, ref.token, authority}, :infinity)

  @doc false
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    context = opts[:context]

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Sup.registry(context.supervisor), {:writers, context.id}}}
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Lemieux.ID.generate()
    parent = opts[:parent]
    context = opts[:context]

    {:ok, custody} =
      DynamicSupervisor.start_child(
        Sup.background_supervisor(context.supervisor),
        {Custody,
         owner: self(),
         parent: parent,
         workspace: opts[:workspace],
         id: id,
         supervisor: context.supervisor,
         store: context.store}
      )

    :ok = Session.subscribe(parent, self())
    :ok = Session.register_work_owner(parent, id, self())
    clock = Keyword.get(opts, :clock)
    timer = Clock.send_after(clock, self(), :deadline, opts[:timeout_ms])

    writers =
      Map.new(
        opts[:plans],
        &{&1.id,
         %{
           id: &1.id,
           status: :starting,
           transcript_id: nil,
           session: nil,
           artifact: nil,
           error: nil
         }}
      )

    state = %{
      id: id,
      token: make_ref(),
      parent: parent,
      parent_ref: Process.monitor(parent),
      context: context,
      custody: custody,
      custody_ref: Process.monitor(custody),
      budget_ref: Process.monitor(context.job_budget),
      opts: opts,
      writers: writers,
      tasks: %{},
      waiters: %{},
      status: :running,
      revision: 0,
      timer: timer,
      clock: clock,
      deadline_at: Clock.now_ms(clock) + opts[:timeout_ms],
      integration: nil,
      integration_result: nil,
      accepted_digests: [],
      pending_plans: opts[:plans]
    }

    {:ok, record(state), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call(:ref, _from, state),
    do: {:reply, {:ok, %Ref{pid: self(), token: state.token, id: state.id}}, state}

  def handle_call({:snapshot, token}, _from, %{token: token} = state),
    do: {:reply, {:ok, result(state)}, state}

  def handle_call({:await, token}, from, %{token: token} = state) do
    cond do
      state.status != :running ->
        {:reply, {:ok, result(state)}, state}

      map_size(state.waiters) >= 64 ->
        {:reply, {:error, :observer_limit}, state}

      true ->
        ref = Process.monitor(elem(from, 0))
        {:noreply, %{state | waiters: Map.put(state.waiters, ref, from)}}
    end
  end

  def handle_call({:cancel, token, authority}, _from, %{token: token} = state) do
    case authorized(state, :cancel, authority) do
      :ok -> {:reply, :ok, stop_writers(state, :cancelled)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:close, token, authority}, _from, %{token: token} = state) do
    case authorized(state, :close, authority) do
      :ok ->
        state =
          if state.status in [:running, :integrating],
            do: stop_writers(state, :cancelled),
            else: state

        {:stop, :normal, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:integrate, token, digests, authority}, from, %{token: token} = state) do
    with true <- state.status == :ready,
         :ok <- authorized(state, :review, authority),
         {:ok, remaining} <- integration_deadline(state),
         {:ok, accepted} <- accepted(state, digests) do
      :ok = Session.subscribe(state.parent, self())
      :ok = Session.register_work_owner(state.parent, state.id, self())
      timer = Clock.send_after(state.clock, self(), :deadline, remaining)
      coordinator = self()

      task =
        Task.Supervisor.async_nolink(Sup.task_supervisor(state.context.supervisor), fn ->
          Workspace.call(state.opts[:workspace], :integrate, [
            accepted,
            state.opts[:checks],
            fn -> GenServer.call(coordinator, {:authorize_integration, authority}) end
          ])
        end)

      {:noreply,
       %{
         state
         | status: :integrating,
           integration: {task, from},
           accepted_digests: digests,
           timer: timer
       }}
    else
      false -> {:reply, {:error, :not_ready}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:authorize_integration, authority}, _from, state) do
    reply =
      if state.status == :integrating and Process.alive?(state.parent),
        do: authorized(state, :integrate, authority),
        else: {:error, :cancelled}

    {:reply, reply, state}
  end

  def handle_call(
        {:writer_started, id, session, transcript_id},
        _from,
        %{status: :running} = state
      ) do
    writer = %{
      state.writers[id]
      | session: session,
        transcript_id: transcript_id,
        status: :running
    }

    {:reply, :ok, record(%{state | writers: Map.put(state.writers, id, writer)})}
  end

  def handle_call({:writer_patch, id, artifact}, _from, %{status: :running} = state) do
    :ok = Custody.captured(state.custody, id)
    {:reply, :ok, record(put_in(state.writers[id].artifact, artifact))}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_cast({:withdraw_await, token, caller}, %{token: token} = state) do
    {removed, kept} =
      Enum.split_with(state.waiters, fn {_ref, from} -> elem(from, 0) == caller end)

    Enum.each(removed, fn {ref, _from} -> Process.demonitor(ref, [:flush]) end)
    {:noreply, %{state | waiters: Map.new(kept)}}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, outcome}, %{integration: {%Task{ref: ref}, from}} = state) do
    Process.demonitor(ref, [:flush])
    status = if match?({:ok, _}, outcome), do: :integrated, else: :ready
    Clock.cancel(state.clock, state.timer)
    unregister(state)
    proof = integration_proof(outcome, state.accepted_digests)
    state = record(%{state | integration: nil, status: status, integration_result: proof})
    GenServer.reply(from, outcome)
    {:noreply, state}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {{id, _task}, tasks} ->
        Process.demonitor(ref, [:flush])

        writer =
          case outcome do
            {:ok, artifact} ->
              %{state.writers[id] | status: :completed, artifact: artifact}

            {:error, reason} ->
              %{state.writers[id] | status: :failed, error: reason}

            {:error, reason, artifact} ->
              %{state.writers[id] | status: :failed, error: reason, artifact: artifact}
          end

        state = %{state | tasks: tasks, writers: Map.put(state.writers, id, writer)}
        {:noreply, state |> schedule() |> settle()}
    end
  end

  def handle_info({:writer_preserved, id, artifact}, state),
    do: {:noreply, record(put_in(state.writers[id].artifact, artifact))}

  def handle_info({:writer_violation, id, reason}, state) do
    state = put_in(state.writers[id].error, reason)
    {:noreply, stop_writers(state, :failed)}
  end

  def handle_info({:cleanup_failed, id, error}, state) do
    state = put_in(state.writers[id].error, {:cleanup_failed, error})
    {:noreply, stop_writers(state, :failed)}
  end

  def handle_info(:deadline, %{status: status} = state) when status in [:running, :integrating],
    do: {:noreply, stop_writers(state, :timed_out)}

  def handle_info(:deadline, state), do: {:noreply, state}

  def handle_info({:parent_cancel, _reason}, state),
    do: {:noreply, stop_writers(state, :cancelled)}

  def handle_info({:lemieux, _id, {:entry, %{type: :cancelled}}}, state),
    do: {:noreply, stop_writers(state, :cancelled)}

  def handle_info({:lemieux, _id, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when ref == state.parent_ref or ref == state.custody_ref or ref == state.budget_ref,
      do: {:noreply, stop_writers(state, :interrupted)}

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{integration: {%Task{ref: ref}, from}} = state
      ) do
    outcome = {:error, {:integration_interrupted, reason}}
    Clock.cancel(state.clock, state.timer)
    unregister(state)

    state =
      record(%{
        state
        | integration: nil,
          status: :failed,
          integration_result: integration_proof(outcome, state.accepted_digests)
      })

    GenServer.reply(from, outcome)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{waiters: waiters} = state)
      when is_map_key(waiters, ref), do: {:noreply, %{state | waiters: Map.delete(waiters, ref)}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    handle_info({ref, {:error, {:writer_down, reason}}}, state)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, {_id, task}} -> Task.shutdown(task, 0) end)
    if state.integration, do: Task.shutdown(elem(state.integration, 0), 0)
    if Process.alive?(state.custody), do: Custody.drain(state.custody)
    unregister(state)
  end

  defp run_writer(coordinator, state, plan) do
    with {:ok, workspace} <- Custody.prepare(state.custody, plan) do
      try do
        with {:ok, options} <- state.opts[:factory].(plan, workspace),
             :ok <- permitted_tools(options, plan, workspace),
             id = Lemieux.ID.generate(),
             environment =
               {Scoped,
                %{
                  environment: workspace.environment,
                  cwd: workspace.cwd,
                  plan: plan,
                  coordinator: coordinator,
                  commands?: workspace.commands?
                }},
             options =
               Keyword.merge(options,
                 supervisor: state.context.supervisor,
                 store: state.context.store,
                 cwd: workspace.cwd,
                 environment: environment,
                 id: id,
                 root_session_id: id,
                 resume: nil,
                 entries: [],
                 job_budget: state.context.job_budget,
                 job_limits: nil,
                 execution: state.context.execution,
                 transcript_lock: true,
                 harness_context: writer_context(options, state, plan, workspace),
                 host_tools: [],
                 mcp_servers: [],
                 provider_limiter: state.context.provider_limiter,
                 provider_limit_key: state.context.provider_limit_key,
                 hooks:
                   state.context.hooks ++
                     Keyword.get(options, :hooks, []) ++ dispatch_hooks(state, plan),
                 max_requests:
                   min(Keyword.get(options, :max_requests, plan.max_requests), plan.max_requests),
                 clock: state.clock,
                 deadline_ms: max(1, state.deadline_at - Clock.now_ms(state.clock))
               ),
             {:ok, session} <- Custody.session(state.custody, plan.id, options) do
          :ok = GenServer.call(coordinator, {:writer_started, plan.id, session, id}, :infinity)

          with {:ok, result} <-
                 Session.await(session, brief(plan), timeout: state.opts[:timeout_ms]),
               :ok <- successful(result),
               {:ok, report} <- JSON.decode(result.text),
               result = Map.put(result, :report, report),
               {:ok, pending} <-
                 Workspace.call(state.opts[:workspace], :export, [
                   workspace,
                   plan,
                   result,
                   %{"status" => "pending", "check" => "host verification"}
                 ]),
               :ok <- GenServer.call(coordinator, {:writer_patch, plan.id, pending}, :infinity) do
            verify_writer(state, workspace, plan, result)
          end
        end
      after
        case Custody.release(state.custody, plan.id) do
          :ok -> :ok
          error -> send(coordinator, {:cleanup_failed, plan.id, error})
        end
      end
    end
  end

  defp verify_writer(state, workspace, plan, result) do
    case Worktree.checked(
           fn _cwd -> state.opts[:verify].(workspace, plan, result) end,
           workspace.cwd
         ) do
      {:ok, evidence} ->
        Workspace.call(state.opts[:workspace], :export, [workspace, plan, result, evidence])

      {:error, reason} ->
        evidence = %{
          "status" => "failed",
          "check" => "host verification",
          "reason" => inspect(reason, limit: 50, printable_limit: 4096)
        }

        with {:ok, artifact} <-
               Workspace.call(state.opts[:workspace], :export, [workspace, plan, result, evidence]),
             do: {:error, {:verification_failed, reason}, artifact}
    end
  end

  defp writer_context(options, state, plan, workspace) do
    options
    |> Keyword.get(:harness_context, %{})
    |> Map.put(
      "lemieux.writers",
      %{
        "group_id" => state.id,
        "parent_id" => state.context.id,
        "writer_id" => plan.id,
        "base_revision" => workspace.base_revision
      }
    )
  end

  defp dispatch_hooks(state, plan) do
    context = %{id: state.id, parent_id: state.context.id, writer_id: plan.id, paths: plan.paths}

    authorize = fn purpose ->
      state.opts[:authorize].(
        :dispatch,
        Map.put(context, :purpose, purpose),
        state.opts[:authority]
      )
    end

    [
      prepare_next_turn: fn request, _context ->
        case authorize.(:provider) do
          :ok -> {:ok, request}
          {:error, _reason} -> {:deny, "writer dispatch is not currently authorized"}
        end
      end,
      before_tool_call: fn _call, _context ->
        case authorize.(:tool) do
          :ok -> :allow
          {:error, _reason} -> {:deny, "writer dispatch is not currently authorized"}
        end
      end
    ]
  end

  defp permitted_tools(options, plan, workspace) do
    tools = Keyword.get(options, :tools)

    if is_list(tools) and
         Enum.all?(tools, fn tool ->
           Tool.name(tool) in plan.tools and
             (workspace.commands? or Tool.read_only?(tool) or
                Tool.descriptor(tool).executor in [
                  Lemieux.Tools.Write,
                  Lemieux.Tools.Edit,
                  Lemieux.Tools.ApplyPatch
                ])
         end), do: :ok, else: {:error, :tool_permissions_not_granted}
  end

  defp successful(%{stop_reason: :stop, error: nil, entries: entries}) do
    if Enum.any?(entries, &(&1.type == :tool_result and &1.payload["error"] == true)),
      do: {:error, :failed_effect},
      else: :ok
  end

  defp successful(result), do: {:error, {:unfinished_writer, result.stop_reason, result.error}}

  defp brief(plan) do
    plan.task <>
      "\n\nYou may write only: " <>
      Enum.join(plan.paths, ", ") <>
      ". Return a JSON object with summary, critical_findings (array), and uncertainties (array). " <>
      "Preserve every critical finding. Do not integrate or publish changes."
  end

  defp settle(%{tasks: tasks, status: :running} = state) when map_size(tasks) == 0 do
    Clock.cancel(state.clock, state.timer)

    status =
      if Enum.all?(state.writers, fn {_id, writer} -> writer.status == :completed end),
        do: :ready,
        else: :failed

    state = record(%{state | status: status})
    unregister(state)
    reply_waiters(state)
  end

  defp settle(state), do: state

  defp stop_writers(state, status) do
    Enum.each(state.tasks, fn {_ref, {_id, task}} -> Task.shutdown(task, 0) end)

    if state.integration do
      Task.shutdown(elem(state.integration, 0), 0)
      GenServer.reply(elem(state.integration, 1), {:error, :cancelled})
    end

    if Process.alive?(state.custody), do: Custody.drain(state.custody)

    writers =
      Map.new(state.writers, fn {id, writer} ->
        {id, if(writer.status == :completed, do: writer, else: %{writer | status: status})}
      end)

    Clock.cancel(state.clock, state.timer)

    state =
      record(%{
        state
        | status: status,
          tasks: %{},
          writers: writers,
          integration: nil,
          pending_plans: []
      })

    unregister(state)
    reply_waiters(state)
  end

  defp reply_waiters(state) do
    Enum.each(state.waiters, fn {ref, from} ->
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:ok, result(state)})
    end)

    %{state | waiters: %{}}
  end

  defp unregister(state) do
    if Process.alive?(state.parent) do
      Session.unregister_work_owner(state.parent, state.id)
      Session.unsubscribe(state.parent, self())
    end
  end

  defp result(state) do
    budget =
      if Process.alive?(state.context.job_budget),
        do: JobBudget.snapshot(state.context.job_budget)

    %{
      id: state.id,
      status: state.status,
      budget: budget,
      integration: state.integration_result,
      writers: Enum.map(state.opts[:plans], &state.writers[&1.id])
    }
  end

  defp json_budget(budget) do
    if Process.alive?(budget) do
      budget
      |> JobBudget.snapshot()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end

  defp record(state) do
    if Process.alive?(state.parent) do
      value = %{
        "id" => state.id,
        "status" => Atom.to_string(state.status),
        "integration" => state.integration_result,
        "budget" => json_budget(state.context.job_budget),
        "writers" =>
          Enum.map(state.opts[:plans], fn plan ->
            writer = state.writers[plan.id]

            %{
              "id" => writer.id,
              "status" => Atom.to_string(writer.status),
              "paths" => plan.paths,
              "tools" => plan.tools,
              "transcript_id" => writer.transcript_id,
              "artifact" => if(writer.artifact, do: Artifact.reference(writer.artifact)),
              "error" =>
                if(writer.error, do: inspect(writer.error, limit: 20, printable_limit: 1024))
            }
          end)
      }

      {:ok, document} =
        Session.put_document(state.parent, "lemieux.writers." <> state.id, state.revision, value)

      %{state | revision: document.revision}
    else
      state
    end
  end

  defp authorized(state, action, authority),
    do: state.opts[:authorize].(action, %{id: state.id, parent_id: state.context.id}, authority)

  defp accepted(state, digests) when is_list(digests) and digests != [] do
    artifacts = state.writers |> Map.values() |> Enum.map(& &1.artifact)
    selected = Enum.map(digests, fn digest -> Enum.find(artifacts, &(&1.digest == digest)) end)

    if length(digests) == length(Enum.uniq(digests)) and Enum.all?(selected, & &1),
      do: {:ok, selected},
      else: {:error, :unreviewed_artifact}
  end

  defp accepted(_state, _digests), do: {:error, :unreviewed_artifact}

  defp top_level(%{id: id, root_session_id: id}), do: :ok
  defp top_level(_context), do: {:error, :delegated_parent}

  defp validate(plans, opts) when is_list(plans) and length(plans) in 1..4 do
    with :ok <- validate_plans(plans), do: validate_options(opts)
  end

  defp validate(_plans, _opts), do: {:error, :invalid_briefs}

  defp validate_plans(plans) do
    cond do
      not Enum.all?(plans, &Plan.valid?/1) ->
        {:error, :invalid_briefs}

      length(Enum.uniq_by(plans, & &1.id)) != length(plans) ->
        {:error, :duplicate_writer}

      byte_size(JSON.encode!(Enum.map(plans, &Map.from_struct/1))) > 24_000 ->
        {:error, :briefs_too_large}

      true ->
        overlap(plans)
    end
  end

  defp overlap(plans) do
    pairs =
      for {left, i} <- Enum.with_index(plans),
          {right, j} <- Enum.with_index(plans),
          i < j and Plan.overlaps?(left, right),
          do: {left.id, right.id}

    case pairs do
      [] -> :ok
      [{left, right} | _] -> {:error, {:overlapping_scopes, left, right}}
    end
  end

  defp validate_options(opts) do
    callbacks? =
      Enum.all?(
        [factory: 2, verify: 3, checks: 1, authorize: 3],
        fn {key, arity} -> is_function(opts[key], arity) end
      )

    timeout = Keyword.get(opts, :timeout_ms, 3_600_000)

    cond do
      not callbacks? or not match?({module, _} when is_atom(module), opts[:workspace]) ->
        {:error, :missing_host_policy}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, :invalid_deadline}

      Keyword.get(opts, :max_active, 4) not in 1..4 ->
        {:error, :invalid_concurrency}

      true ->
        :ok
    end
  end

  defp schedule(%{status: :running, pending_plans: [plan | rest]} = state) do
    if map_size(state.tasks) < Keyword.get(state.opts, :max_active, 4) do
      owner = self()

      task =
        Task.Supervisor.async_nolink(
          Sup.task_supervisor(state.context.supervisor),
          fn -> run_writer(owner, state, plan) end
        )

      schedule(%{
        state
        | tasks: Map.put(state.tasks, task.ref, {plan.id, task}),
          pending_plans: rest
      })
    else
      state
    end
  end

  defp schedule(state), do: state

  defp integration_proof({:ok, details}, digests) do
    %{
      "transaction_id" => Map.get(details, :transaction_id),
      "accepted" => digests,
      "checks" => Map.get(details, :checks),
      "staged_checks" => Map.get(details, :staged_checks)
    }
  end

  defp integration_proof({:error, reason}, _digests),
    do: %{"error" => inspect(reason, printable_limit: 1024)}

  defp timeout(parent, opts) do
    requested = Keyword.get(opts, :timeout_ms, 3_600_000)

    case Session.budget(parent).time_left_ms do
      nil -> requested
      remaining -> max(1, min(requested, remaining))
    end
  end

  defp integration_deadline(state) do
    remaining = state.deadline_at - Clock.now_ms(state.clock)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :deadline_exceeded}
  end
end
