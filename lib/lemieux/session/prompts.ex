defmodule Lemieux.Session.Prompts do
  @moduledoc false

  require Logger

  alias Lemieux.Clock
  alias Lemieux.Hooks
  alias Lemieux.MCP
  alias Lemieux.Messages
  alias Lemieux.Reference
  alias Lemieux.Request
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.MCPServers
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Requests
  alias Lemieux.Session.State
  alias Lemieux.Session.ToolWave
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Telemetry
  alias Lemieux.Tool

  def start_prompt_hook(state, from, text) do
    if Hooks.registered?(state.hooks, :user_prompt) do
      hooks = state.hooks
      context = hook_context(state)

      {:noreply,
       start_hook(state, {:prompt, from, text}, fn ->
         Hooks.user_prompt(hooks, text, context)
       end)}
    else
      {:noreply, expand(state, {:prompt, from}, text)}
    end
  end

  def start_follow_up_hook(state, text) do
    if Hooks.registered?(state.hooks, :user_prompt) do
      hooks = state.hooks
      context = hook_context(state)

      start_hook(state, {:follow_up, text}, fn ->
        Hooks.user_prompt(hooks, text, context)
      end)
    else
      expand(state, :follow_up, text)
    end
  end

  defp accept_prompt(state, text, attachments) do
    state
    |> begin_run()
    |> Core.append({:user, user_payload(text, attachments), nil})
    # A new prompt is new information, so whatever the last prompt kept
    # asking for is no longer evidence about this one — a person who says
    # "try it again now" deserves to have it tried again.
    |> Map.merge(%{
      turns_taken: 0,
      retry_attempt: 0,
      retry_note: nil,
      stop_hook_active: false
    })
    |> Core.forget_wave()
    |> Core.forget_context_recovery()
    |> Instrumentation.start_prompt_telemetry()
    |> Compacting.continue()
  end

  def begin_run(state) do
    sequence = state.evidence.run_sequence + 1

    run_id =
      case {sequence, Map.get(state.evidence.correlation_ids, "run_id")} do
        {1, id} when is_binary(id) and id != "" -> id
        _other -> "run_" <> Lemieux.ID.generate()
      end

    correlations =
      Map.merge(state.evidence.correlation_ids, %{
        "session_id" => state.id,
        "root_session_id" => state.root_session_id,
        "run_id" => run_id
      })

    %{
      state
      | evidence: %{
          state.evidence
          | current_run: %{
              id: run_id,
              correlations: correlations,
              start_seq: state.next_seq,
              started_at: System.monotonic_time(:millisecond),
              pending_request: nil,
              request_ordinal: 0,
              hook_outcomes: []
            },
            current_harness_snapshot: nil,
            run_sequence: sequence
        }
    }
  end

  # The key is absent rather than empty when nothing was attached, so a prompt
  # that used no references writes the entry it has always written — which is
  # what keeps every existing transcript, and every older reader, unchanged.
  defp user_payload(text, []), do: %{"text" => text}
  defp user_payload(text, attachments), do: %{"text" => text, "attachments" => attachments}

  # Expansion sits between the hook and the entry on purpose. Before the hook, a
  # policy that rewrites a prompt would be handed an already-inflated blob and one
  # that denies it would have caused a pile of file reads for nothing. After the
  # entry, the attachments would not be in the transcript, so a resumed or forked
  # session would rebuild a different request from the same conversation — and
  # re-reading at request time would rebuild it differently again every time the
  # working tree moved. `Lemieux.Request` promises the request is a function of the
  # entries.
  #
  # A prompt with no references takes the synchronous path: parsing is a regex over
  # one string, but reading N files through an environment a host may have pointed
  # at a container is not, and doing that in the session process would stall
  # snapshots, cancellations and steers. Historical references in replayed evidence
  # never cause fresh reads.
  # An aside's text is a request a program composed, not a line a person
  # typed, and its evidence is in its system text; there is nothing to attach.
  defp expand(%{aside: %Aside{}} = state, resume, text), do: resume(state, resume, text, [])

  defp expand(state, resume, text) do
    case Reference.parse(text) do
      [] -> resume(state, resume, text, [])
      refs -> start_hook(state, {:expand, resume, text}, expansion(state, refs))
    end
  end

  # Built outside the closure so the task captures a few immutable terms rather
  # than the whole session state, which holds every entry written so far.
  defp expansion(%State{environment: environment, cwd: cwd} = state, refs) do
    resource = resource_reader(MCPServers.connected_clients(state))
    fn -> Reference.resolve(refs, environment, cwd, resource: resource) end
  end

  # How a prompt's `@server:uri` is read: through the client the session
  # already holds for that server, from the expansion task. Never through the
  # session process itself, which is waiting on that very task. A client that
  # died meanwhile is a server no longer connected, not a crashed prompt.
  defp resource_reader(clients) do
    fn server, uri ->
      case List.keyfind(clients, server, 0) do
        {^server, client} -> read_resource(client, uri)
        nil -> {:error, :unknown_server}
      end
    end
  end

  defp read_resource(client, uri) do
    MCP.resource(client, uri)
  catch
    :exit, _reason -> {:error, "the server disconnected"}
  end

  defp resume(state, {:prompt, from}, text, attachments) do
    GenServer.reply(from, :ok)
    accept_prompt(state, text, attachments)
  end

  defp resume(state, :follow_up, text, attachments),
    do: accept_prompt(state, text, attachments)

  def start_refresh(state, from) do
    case attached_references(state) do
      [] -> {:reply, {:ok, 0}, state}
      refs -> {:noreply, start_hook(state, {:refresh, from}, expansion(state, refs))}
    end
  end

  # Built from the paths already on the transcript rather than by re-parsing the
  # prompts: a glob attached the files it matched, and re-running it would quietly
  # pick up files that were never part of this conversation. Explicit, because a
  # file attached deliberately and since deleted is worth saying so about.
  defp attached_references(state) do
    state
    |> stored_attachments()
    |> Enum.map(&Reference.from_attachment/1)
    |> Enum.uniq_by(& &1.path)
  end

  defp previously_attached(state), do: Map.new(stored_attachments(state), &{&1["path"], &1})

  defp stored_attachments(state) do
    state
    |> Core.entries()
    |> Enum.filter(&(&1.type == :user))
    |> Enum.flat_map(&Map.get(&1.payload, "attachments", []))
  end

  defp changed(previous, attachments) do
    Enum.reject(attachments, fn attachment ->
      case Map.fetch(previous, attachment["path"]) do
        {:ok, stored} -> unmoved?(stored, attachment)
        :error -> false
      end
    end)
  end

  defp unmoved?(stored, attachment) do
    Map.get(stored, "text") == Map.get(attachment, "text") and
      Map.get(stored, "data") == Map.get(attachment, "data")
  end

  defp refreshed(state, changed),
    do: Messages.render(state.messages, :attachments_refreshed, [Enum.map(changed, & &1["path"])])

  def start_stop_hook(state, stop_reason) do
    if Hooks.registered?(state.hooks, :stop) do
      hooks = state.hooks
      # The effective hooks ride along, as they do in a tool's context
      # (`Lemieux.Tools.run/5`): a stop hook that runs a command for the
      # session — `Lemieux.Extensions.Verify` — puts it to the same
      # `before_tool_call` policy the model's own commands meet.
      context = Map.put(hook_context(state), :hooks, hooks)

      start_hook(state, {:stop, stop_reason}, fn ->
        Hooks.stop(hooks, stop_reason, context)
      end)
    else
      finish_stop(state, stop_reason)
    end
  end

  def start_hook(state, action, fun) do
    task = Task.Supervisor.async(Sup.task_supervisor(state.supervisor), fun)
    %{state | hook_task: %{task: task, action: action}}
  end

  def finish_hook(state, {:expand, resume, text}, attachments) when is_list(attachments),
    do: resume(state, resume, text, attachments)

  def finish_hook(state, {:refresh, from}, attachments) when is_list(attachments) do
    case changed(previously_attached(state), attachments) do
      [] ->
        GenServer.reply(from, {:ok, 0})
        state

      changed ->
        GenServer.reply(from, {:ok, length(changed)})
        accept_prompt(state, refreshed(state, changed), changed)
    end
  end

  def finish_hook(state, {:prompt, from, _original}, {:ok, text}),
    do: expand(state, {:prompt, from}, text)

  def finish_hook(state, {:prompt, from, _original}, {:deny, reason}) do
    GenServer.reply(from, {:error, {:hook_denied, reason}})
    %{state | aside: nil}
  end

  def finish_hook(state, {:follow_up, _original}, {:ok, text}),
    do: expand(state, :follow_up, text)

  def finish_hook(state, {:follow_up, _original}, {:deny, reason}) do
    state
    |> Core.append({:error, %{"reason" => "follow-up denied: #{inspect(reason)}"}, nil})
    |> Recovery.maybe_follow_up()
  end

  def finish_hook(state, {:prepare_next_turn, _original}, {:ok, %Request{} = request}) do
    case Tool.validate_all(request.tools) do
      :ok -> Requests.dispatch_request(state, request)
      {:error, reason} -> Requests.request_hook_failed(state, {:invalid_tool_catalog, reason})
    end
  end

  def finish_hook(state, {:prepare_next_turn, _original}, {:deny, reason}) do
    Requests.request_hook_failed(state, {:denied, reason})
  end

  def finish_hook(state, {:stop, stop_reason}, :allow), do: finish_stop(state, stop_reason)

  # A stop hook's veto continues a turn with the hook's feedback; continuing an
  # aside would be an autonomous loop on a request nobody is steering.
  def finish_hook(%{aside: %Aside{}} = state, {:stop, _reason}, {:deny, _feedback}),
    do: finish_stop(state, :hook_failed)

  def finish_hook(state, {:stop, _stop_reason}, {:deny, feedback}) do
    if state.turns_taken < state.max_turns do
      # Not expanded: this text is a hook's, not a person's, and a policy that
      # wants a file in front of the model can put its contents there itself.
      state
      |> Core.append({:user, %{"text" => feedback}, nil})
      |> Map.put(:stop_hook_active, true)
      |> Compacting.continue()
    else
      ToolWave.stop(
        state,
        :max_turns,
        Messages.render(state.messages, :turn_budget_spent, [state.max_turns])
      )
    end
  end

  def finish_stop(state, stop_reason) do
    state
    |> Core.put_compaction(:preflight_attempted?, false)
    |> Core.put_compaction(:trigger, nil)
    |> Core.put_compaction(:forecast, nil)
    |> Map.merge(%{stop_hook_active: false, retry_note: nil, retry_failure: nil})
    |> Instrumentation.finish_prompt_telemetry(stop_reason)
    |> Audit.finalize_run(stop_reason)
    |> Core.emit({:context, Compacting.context(state)})
    |> Core.emit({:finished, stop_reason})
    |> Recovery.maybe_follow_up()
  end

  def hook_crashed(state, {:refresh, from}, reason) do
    Logger.warning("lemieux: refreshing attachments failed: #{Exception.format_exit(reason)}")
    GenServer.reply(from, {:error, {:refresh_failed, reason}})

    state
  end

  # A prompt whose references could not be read is still a prompt. Losing it
  # would be a worse answer than sending it without the files.
  def hook_crashed(state, {:expand, resume, text}, reason) do
    Logger.warning(
      "lemieux: expanding prompt references failed: #{Exception.format_exit(reason)}"
    )

    resume(state, resume, text, [])
  end

  def hook_crashed(state, {:prompt, from, _text}, reason) do
    GenServer.reply(from, {:error, {:hook_failed, reason}})
    %{state | aside: nil}
  end

  def hook_crashed(state, {:follow_up, _text}, reason) do
    Logger.warning("lemieux: follow-up hook failed: #{Exception.format_exit(reason)}")

    state
    |> Core.append({:error, %{"reason" => "follow-up hook failed"}, nil})
    |> Recovery.maybe_follow_up()
  end

  def hook_crashed(state, {:prepare_next_turn, _request}, reason) do
    Requests.request_hook_failed(state, {:crashed, reason})
  end

  def hook_crashed(state, {:stop, stop_reason}, reason) do
    Logger.warning("lemieux: stop hook failed: #{Exception.format_exit(reason)}")
    finish_stop(state, stop_reason)
  end

  defp reply_cancelled_hook(%{action: {:prompt, from, _text}}),
    do: GenServer.reply(from, {:error, :cancelled})

  defp reply_cancelled_hook(%{action: {:expand, {:prompt, from}, _text}}),
    do: GenServer.reply(from, {:error, :cancelled})

  defp reply_cancelled_hook(%{action: {:refresh, from}}),
    do: GenServer.reply(from, {:error, :cancelled})

  defp reply_cancelled_hook(_hook), do: :ok

  def observe_async(state, fun) do
    case Task.Supervisor.start_child(Sup.task_supervisor(state.supervisor), fun) do
      {:ok, _pid} ->
        state

      {:error, reason} ->
        Logger.warning("lemieux: could not start hook: #{inspect(reason)}")
        state
    end
  end

  def observe_attention(%{attention_observer: nil} = state, _payload), do: state

  def observe_attention(%{attention_observer: observer} = state, payload) do
    send(observer, {:attention, payload, hook_context(state)})
    state
  end

  def observe_working(%{parked: parked} = state) when map_size(parked) == 0,
    do: observe_attention(state, %{state: :working})

  def observe_working(state), do: state

  def start_attention_observer(supervisor, hooks, session) do
    if Hooks.registered?(hooks, :attention),
      do: do_start_attention_observer(supervisor, hooks, session)
  end

  defp do_start_attention_observer(supervisor, hooks, session) do
    case Task.Supervisor.start_child(Sup.task_supervisor(supervisor), fn ->
           session_ref = Process.monitor(session)
           attention_loop(session_ref, hooks)
         end) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.warning("lemieux: could not start attention observer: #{inspect(reason)}")
        nil
    end
  end

  defp attention_loop(session_ref, hooks) do
    receive do
      {:attention, payload, context} ->
        Hooks.attention(hooks, payload, context)
        attention_loop(session_ref, hooks)

      {:DOWN, ^session_ref, :process, _session, _reason} ->
        :ok
    end
  end

  # `environment` is here for command hooks: which credential-shaped variables
  # a hook's process may see is the environment's policy (`Lemieux.Environment`),
  # and a hook without it would inherit the whole process environment.
  def hook_context(state) do
    %{
      cwd: state.cwd,
      environment: state.environment,
      session_id: state.id,
      # A delegated subagent's root is another session; `Lemieux.Hooks`
      # keeps the main session's Claude Code SessionStart hooks out of it.
      root_session_id: state.root_session_id,
      session: self(),
      supervisor: state.supervisor,
      stop_hook_active: state.stop_hook_active,
      spent_usd: state.spent_usd,
      max_cost_usd: state.max_cost_usd
    }
  end

  defp drop_provider_retry(%{provider_retry: nil} = state), do: state

  defp drop_provider_retry(%{provider_retry: retry} = state) do
    Clock.cancel(state.clock, retry.timer)
    %{state | provider_retry: nil, retry_note: nil, retry_failure: nil}
  end

  # Nothing is released: the tasks that were waiting have just been killed, so
  # there is nobody left to answer. Dropping the timers stops a call that no
  # longer exists being "denied" minutes later.
  defp drop_parked(%{parked: parked} = state) when map_size(parked) == 0, do: state

  defp drop_parked(state) do
    Enum.each(state.parked, fn {_call_id, waiting} ->
      Approvals.cancel_timer(state, waiting.timer)
    end)

    %{state | parked: %{}} |> observe_working()
  end

  # A call that ended while parked — it crashed, or its deadline had already
  # fired when it parked — takes its waiting entry with it. Left behind, a later
  # answer would be recorded as approving a call that never ran.
  def drop_parked_call(state, call_id) do
    case Map.pop(state.parked, call_id) do
      {nil, _parked} ->
        state

      {waiting, parked} ->
        Approvals.cancel_timer(state, waiting.timer)
        observe_working(%{state | parked: parked})
    end
  end

  def do_cancel(state, reason) do
    Telemetry.event(
      [:session, :cancel],
      %{},
      Instrumentation.telemetry_metadata(state, %{stop_reason: reason})
    )

    Enum.each(state.subagent_groups, fn {_group_id, group} ->
      send(group, {:parent_cancel, reason})
    end)

    # A timeout-zero shutdown is still an exit signal, not a mailbox request:
    # provider HTTP reads and tools blocked in commands stop immediately. The
    # `:shutdown` reason lets OTP children linked by those libraries terminate
    # normally rather than dumping state as a `:killed` crash, and Task falls back
    # to a kill at once if a process traps the signal.
    if state.task, do: Task.shutdown(state.task, 0)
    if state.hook_task, do: Task.shutdown(state.hook_task.task, 0)

    Enum.each(state.wave.tool_tasks, fn {
                                          _ref,
                                          {task, call, _stream_ref, started, timer, _descriptor}
                                        } ->
      Approvals.cancel_timer(state, timer)

      Telemetry.stop_ms(
        [:tool, :call],
        max(System.monotonic_time(:millisecond) - started, 0),
        Instrumentation.telemetry_metadata(state, %{
          tool_name: call.name,
          call_id: call.id,
          outcome: :cancelled
        })
      )

      Task.shutdown(task, 0)
    end)

    Compacting.cancel_compacting(state, state.compaction.compacting)
    Compacting.cancel_mcp_wait(state, state.mcp_wait)

    reply_cancelled_hook(state.hook_task)

    state =
      state
      |> drop_provider_retry()
      |> ToolWave.checkpoint_turn()
      |> ToolWave.checkpoint_cancelled_tools()
      |> drop_parked()
      |> Accounting.account_missing_usage()
      |> Instrumentation.finish_turn_telemetry(:cancelled)
      |> Instrumentation.finish_prompt_telemetry(:cancelled)

    %{
      state
      | turn: nil,
        turn_ref: nil,
        task: nil,
        hook_task: nil,
        compaction: %{state.compaction | compacting: nil},
        mcp_wait: nil,
        # The rest of the wave is abandoned with the turn that asked for it.
        # Leaving it queued would start the next writer after the cancel, which
        # is the opposite of what cancelling means.
        wave: %{
          state.wave
          | tool_tasks: %{},
            tool_results: %{},
            tool_order: [],
            tool_batches: []
        },
        # Whatever was queued belonged to the work being abandoned. Carrying it
        # forward would deliver it to whatever gets prompted next, which is not
        # what the person who cancelled asked for.
        reversed_steers: [],
        reversed_follow_ups: [],
        subagent_groups: %{}
    }
    |> Audit.ensure_harness_snapshot()
    |> Core.append({:cancelled, %{"reason" => Atom.to_string(reason)}, nil})
    |> Audit.finalize_run(:cancelled)
    # Every other way a prompt ends publishes the position; this one did not,
    # so a cancelled turn's own spend never reached a status line. The
    # children are still stopping as this returns, and each result they write
    # publishes it again through `delegated_settled/2`.
    |> then(&Core.emit(&1, {:context, Compacting.context(&1)}))
    |> Core.emit({:finished, :cancelled})
  end
end
