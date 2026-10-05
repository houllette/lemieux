defmodule Lemieux.Session.Mailbox do
  @moduledoc false

  alias Lemieux.Clock
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.MCPServers
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Requests
  alias Lemieux.Session.Subscribers
  alias Lemieux.Session.ToolWave
  alias Lemieux.Session.Window
  alias Lemieux.Usage

  def message({:park_timeout, call_id}, state) do
    case Map.pop(state.parked, call_id) do
      {nil, _parked} ->
        {:noreply, state}

      {waiting, parked} ->
        state =
          state
          |> Map.put(:parked, parked)
          |> Core.append({
            :approval,
            Approvals.approval_payload(call_id, waiting.kind, :timed_out, %{}),
            nil
          })
          |> Prompts.observe_working()

        {:noreply,
         Approvals.release(
           state,
           call_id,
           waiting,
           waiting.timeout_reply || Approvals.timed_out(state, waiting.kind)
         )}
    end
  end

  def message(
        {:provider_event, ref, {:response_metadata, metadata}},
        %{turn_ref: ref} = state
      ) do
    {:noreply,
     Core.emit(
       state,
       {:response_metadata, Map.put(metadata, :request_id, state.current_request_id)}
     )}
  end

  # Not output, and not progress: the window the server says it gave the
  # model, which the next request is planned against. One that is not a
  # positive count is a provider bug and says nothing.
  def message({:provider_event, ref, {:context_window, window}}, %{turn_ref: ref} = state) do
    if is_integer(window) and window > 0,
      do: {:noreply, Window.learn_served(state, window)},
      else: {:noreply, state}
  end

  def message({:provider_event, ref, {:usage, usage}}, %{turn_ref: ref} = state)
      when is_map(usage) do
    usage =
      usage |> Usage.normalize(state.model) |> Map.put("request_id", state.current_request_id)

    {:noreply, state |> Accounting.account_usage(usage) |> Recovery.fold({:usage, usage})}
  end

  def message(
        {:provider_event, ref, {:error, reason}},
        %{turn_ref: ref, compaction: %{context_recovery_reason: nil}} = state
      ) do
    state = Catalog.learn_window(state, reason)

    cond do
      Recovery.recoverable_context_error?(state, reason) ->
        {:noreply,
         %{
           state
           | compaction: %{
               state.compaction
               | context_recovery_attempted?: true,
                 context_recovery_reason: reason
             }
         }}

      Recovery.retryable_now?(state, reason) ->
        {:noreply, Recovery.begin_provider_retry(state, reason)}

      true ->
        {:noreply, Recovery.fold(state, {:error, reason})}
    end
  end

  # The backoff is over. The turn that failed is gone; this builds the
  # request again from the transcript and sends it, which is exactly what a
  # person retyping "continue" would get, without the retyping.
  def message({:provider_retry, ref}, %{provider_retry: %{ref: ref} = retry} = state) do
    state = %{
      state
      | provider_retry: nil,
        turn: nil,
        retry_attempt: retry.attempt,
        retry_failure: {state.turn, retry.reason}
    }

    {:noreply, Requests.start_turn(%{state | retry_note: Recovery.retry_note(retry)})}
  end

  def message({:provider_retry, _stale}, state), do: {:noreply, state}

  def message(
        {:provider_event, ref, _event},
        %{turn_ref: ref, compaction: %{context_recovery_reason: reason}} = state
      )
      when not is_nil(reason) do
    {:noreply, state}
  end

  def message({:provider_event, ref, event}, %{turn_ref: ref} = state) do
    {:noreply,
     state
     |> Requests.maybe_emit_first_delta(event)
     |> Requests.note_provider_progress(event)
     |> Recovery.fold(event)}
  end

  def message({:route_observation, request_id, observation}, state)
      when is_binary(request_id) and is_map(observation) do
    {:noreply,
     Core.emit(state, {:route_observation, Map.put(observation, "request_id", request_id)})}
  end

  def message({ref, result}, %{hook_task: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, Prompts.finish_hook(%{state | hook_task: nil}, state.hook_task.action, result)}
  end

  def message(
        {:DOWN, ref, :process, _pid, reason},
        %{hook_task: %{task: %Task{ref: ref}}} = state
      ) do
    action = state.hook_task.action

    {:noreply, Prompts.hook_crashed(%{state | hook_task: nil}, action, reason)}
  end

  def message({ref, result}, %{compaction: %{compacting: %{task: %Task{ref: ref}}}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, Compacting.finish_compacting(state, result)}
  end

  # The one retry a summary gets is due. The same cut is summarised again;
  # the conversation has not moved while the session waited.
  def message(
        {:compaction_retry, ref},
        %{compaction: %{compacting: %{retry: %{ref: ref}} = compacting}} = state
      ) do
    state =
      state
      |> Core.put_compaction(:compacting, nil)
      |> Core.put_compaction(:trigger, compacting.trigger)

    {:noreply, Compacting.resume_compaction(state, compacting)}
  end

  def message({:compaction_retry, _stale}, state), do: {:noreply, state}

  def message(
        {:DOWN, ref, :process, _pid, reason},
        %{compaction: %{compacting: %{task: %Task{ref: ref}}}} = state
      ) do
    {:noreply,
     state
     |> Compacting.compaction_finished({:crashed, {:summariser_crashed, reason}})
     |> Compacting.after_compaction()}
  end

  def message({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, Recovery.close(%{state | task: nil}, result)}
  end

  def message({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, Recovery.close(%{state | task: nil}, {:error, {:provider_crashed, reason}})}
  end

  def message({ref, result}, state) when is_map_key(state.wave.tool_tasks, ref) do
    Process.demonitor(ref, [:flush])

    {:noreply, ToolWave.tool_finished(state, ref, result)}
  end

  def message({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.wave.tool_tasks, ref) do
    # A tool that took its process down with it. The model still gets a
    # result, because "the tool crashed" is something it can work with and a
    # silently missing tool_result is not: a provider rejects an assistant
    # turn whose calls were not all answered.
    {:noreply, ToolWave.tool_finished(state, ref, {:crashed, reason})}
  end

  def message({ref, result}, state) when is_map_key(state.mcp_pending, ref) do
    Process.demonitor(ref, [:flush])

    {:noreply, MCPServers.settle_mcp_connection(state, ref, result)}
  end

  def message({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.mcp_pending, ref) do
    {name, _task} = Map.fetch!(state.mcp_pending, ref)
    failure = "connecting crashed: " <> Exception.format_exit(reason)

    {:noreply,
     MCPServers.settle_mcp_connection(state, ref, {:error, %{name: name, reason: failure}})}
  end

  # A server said its tools changed. The next request carries the new list; a
  # request already in flight keeps the catalog it was sent with. A client this
  # session no longer holds is a late message from a server it let go.
  def message(
        {:mcp_tools_changed, %{server: name, client: client, tools: tools} = change},
        state
      ) do
    case Map.get(state.mcp_connections, name) do
      {_previous, clients} ->
        if client in clients,
          do: {:noreply, MCPServers.replace_mcp_tools(state, name, tools, clients, change)},
          else: {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  # Prompts and resources are not in the catalog; a host offering them as
  # commands or references hears that they changed and asks the server again.
  def message({:mcp_list_changed, %{server: name, kind: kind}}, state),
    do: {:noreply, Core.emit(state, {:mcp_list_changed, %{server: name, kind: kind}})}

  # The grace for servers still connecting is spent: the turn goes without
  # them, and no later turn waits for them either — they join when they answer.
  def message({:mcp_grace_over, ref}, %{mcp_wait: %{ref: ref}} = state) do
    state = %{
      state
      | mcp_wait: nil,
        mcp_grace_deadline: Clock.now_ms(state.clock)
    }

    {:noreply, Requests.build_turn(state)}
  end

  def message({:mcp_grace_over, _stale}, state), do: {:noreply, state}

  def message({:tool_timeout, ref, timeout_ms}, state)
      when is_map_key(state.wave.tool_tasks, ref) do
    {task, _call, _stream_ref, _started, _timer, _descriptor} =
      Map.fetch!(state.wave.tool_tasks, ref)

    Task.shutdown(task, 0)
    {:noreply, ToolWave.tool_finished(state, ref, {:timeout, timeout_ms})}
  end

  # A receipt is the tool saying the remote side has committed its effect, sent
  # from inside the call so it survives whatever happens to the call afterwards.
  # Kept only while the call runs: one for a call this wave is not running is a
  # late message from a task whose result is already written.
  def message({:tool_receipt, call_id, receipt}, state) when is_map(receipt) do
    case ToolWave.running_call(state, call_id) do
      nil ->
        {:noreply, state}

      call ->
        state =
          Core.put_wave(
            state,
            :tool_receipts,
            Map.put(state.wave.tool_receipts, call_id, receipt)
          )

        {:noreply,
         Core.emit(state, {:tool_receipt, %{call_id: call_id, name: call.name, receipt: receipt}})}
    end
  end

  def message({:tool_delta, stream_ref, call_id, name, text}, state) do
    running? =
      Enum.any?(state.wave.tool_tasks, fn {
                                            _task_ref,
                                            {_task, _call, ref, _started, _timer, _descriptor}
                                          } ->
        ref == stream_ref
      end)

    if running? do
      {:noreply, Core.emit(state, {:tool_delta, %{call_id: call_id, name: name, text: text}})}
    else
      {:noreply, state}
    end
  end

  def message({:DOWN, ref, :process, subscriber, _reason}, state) do
    case Subscribers.down(state.subscribers, ref, subscriber) do
      {:ok, subscribers} -> {:noreply, %{state | subscribers: subscribers}}
      :error -> {:noreply, state}
    end
  end

  # A late message from a task whose turn has already been accounted for — a
  # cancelled stream still draining, say. Dropping it is the point of tagging
  # events with the turn's reference.
  def message(_message, state), do: {:noreply, state}
end
