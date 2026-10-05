defmodule Lemieux.Session.Requests do
  @moduledoc false

  require Logger

  alias Lemieux.Clock
  alias Lemieux.Hooks
  alias Lemieux.OpenTelemetry
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Window
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Telemetry
  alias Lemieux.Turn

  # A request made while startup servers are still connecting would tell the
  # model it has none of their tools, and it would plan around that. So the
  # turn waits, within the grace `:mcp_grace_ms` allows from the session's
  # start, and `mcp_settled/1` or the grace timer builds it.
  def start_turn(state) do
    case mcp_grace_remaining(state) do
      :infinity -> wait_for_mcp(state, :infinity)
      remaining when remaining > 0 -> wait_for_mcp(state, remaining)
      _spent -> build_turn(state)
    end
  end

  defp mcp_grace_remaining(%{mcp_pending: pending}) when map_size(pending) == 0, do: 0
  defp mcp_grace_remaining(%{mcp_grace_deadline: :infinity}), do: :infinity

  defp mcp_grace_remaining(%{mcp_grace_deadline: deadline} = state),
    do: deadline - Clock.now_ms(state.clock)

  defp wait_for_mcp(state, remaining) do
    ref = make_ref()

    timer =
      if remaining == :infinity,
        do: nil,
        else: Clock.send_after(state.clock, self(), {:mcp_grace_over, ref}, remaining)

    servers = Enum.map(state.mcp_pending, fn {_ref, {name, _task}} -> name end)

    %{state | mcp_wait: %{ref: ref, timer: timer}}
    |> Core.emit({:waiting_for_mcp, %{servers: Enum.sort(servers), timeout_ms: remaining}})
  end

  def build_turn(state) do
    # Drained here rather than where a steer arrives, because this is the one
    # place a request is built: whatever was said while the model was working
    # is in the conversation it is about to be given, and in the transcript in
    # the order it was said.
    state = Recovery.drain_steers(state)

    entries = Core.behavior_entries(state)

    # Both halves come from the same list, so a resumed session and a live one
    # build the same request from the same transcript — which is the property
    # the whole entries-as-messages design exists to keep.
    request = %Request{
      model: state.model,
      system: Compacting.with_summary(state, entries),
      entries: Compacting.sendable(state, entries, request_opts(state)),
      tools: state.tools,
      params: state.params,
      output_schema: state.output_schema
    }

    request = aside_request(state, request)
    state = Audit.remember_pending_request(state, request)

    if Hooks.registered?(state.hooks, :prepare_next_turn) do
      hooks = state.hooks
      context = Map.put(Prompts.hook_context(state), :retry, state.retry_note)

      Prompts.start_hook(state, {:prepare_next_turn, request}, fn ->
        Hooks.prepare_next_turn(hooks, request, context)
      end)
    else
      dispatch_request(state, request)
    end
  end

  # What a request carries of the transcript: attachments shed and old tool
  # output stubbed as configured. One list, so the request, the fallback
  # request evidence is built from, and a price forecast all agree.
  def request_opts(state) do
    [
      keep_attachments: state.compaction.keep_attachments,
      keep_media: state.compaction.keep_media,
      stub_tool_results: state.compaction.stub_tool_results
    ]
  end

  # The aside's system text goes in the request's system field rather than in
  # a user message, so the next turn does not inherit it and compaction never
  # has to summarise it. Its own prompt entry — the one `accept_prompt/3` just
  # wrote — always comes last, so the request ends on the question asked.
  defp aside_request(%{aside: %Aside{} = aside} = state, request) do
    %{
      request
      | system: aside_system(state, aside, request),
        entries: aside_entries(state, aside, request),
        tools: [],
        output_schema: aside.output_schema
    }
  end

  defp aside_request(_state, request), do: request

  # `:transcript` keeps the compaction summary the turn's system text carries,
  # under the aside's own instructions: without it the sendable entries would
  # start mid-conversation with nothing standing in for what was cut.
  defp aside_system(state, %Aside{entries: :transcript, system: system}, _request),
    do: Compacting.with_summary(%{state | system: system}, Core.behavior_entries(state))

  defp aside_system(_state, %Aside{system: system}, _request), do: system

  defp aside_entries(_state, %Aside{entries: :transcript}, request), do: request.entries

  defp aside_entries(state, %Aside{entries: entries}, _request) when is_list(entries),
    do: entries ++ [Enum.find(state.reversed_entries, &(&1.type == :user))]

  # Tool-free is the aside's contract, not its default: a `prepare_next_turn`
  # hook may rewrite the request but cannot hand an aside a tool, and the
  # schema stays the aside's. Anything else is the hook's to change.
  def dispatch_request(%{aside: %Aside{} = aside} = state, request),
    do:
      state
      |> Window.notice()
      |> dispatch(%{request | tools: [], output_schema: aside.output_schema})

  # What the window is, and whether it leaves room, is said here rather than
  # when the session starts: see `Lemieux.Session.Window`.
  def dispatch_request(state, request) do
    state =
      state
      |> Window.notice()
      |> Compacting.prune_advice(request)
      |> Compacting.verify_room(request)

    case Compacting.due?(state, request) do
      {trigger, forecast} ->
        state =
          state
          |> Core.put_compaction(:preflight_attempted?, true)
          |> Core.put_compaction(:trigger, trigger)
          |> Core.put_compaction(:forecast, forecast)

        Compacting.start_compacting(state, nil) || dispatch(state, request)

      false ->
        dispatch(state, request)
    end
  end

  defp dispatch(state, request) do
    state =
      state |> Audit.note_request_hook_outcome(request) |> Audit.prepare_harness_snapshot(request)

    case Accounting.request_budget(state, request) do
      :ok -> start_provider(state, request)
      {:error, payload} -> Accounting.budget_stop(state, payload)
    end
  end

  def request_hook_failed(state, reason) do
    description = "prepare_next_turn hook failed: #{Compacting.describe(reason)}"
    Logger.warning("lemieux: #{description}")

    state
    |> Audit.note_request_hook_failure(reason)
    |> Audit.ensure_harness_snapshot()
    |> Core.append({:error, %{"reason" => description}, nil})
    |> Prompts.finish_stop(:hook_failed)
  end

  defp start_provider(state, request) do
    session = self()
    ref = make_ref()
    provider = state.provider

    request_snapshot =
      RequestSnapshot.build(request, Audit.request_snapshot_opts(state, retry: state.retry_note))

    state =
      state
      |> Core.put_compaction(:preflight_attempted?, false)
      |> Core.put_compaction(:advice, nil)
      |> Core.put_compaction(:trigger, nil)
      |> Core.put_compaction(:forecast, nil)
      |> then(
        &Core.append(
          %{&1 | retry_note: nil, retry_failure: nil},
          {:request, request_snapshot, nil}
        )
      )

    request_id = RequestSnapshot.id(request_snapshot)

    turn_started_at =
      Telemetry.start(
        [:turn],
        Instrumentation.telemetry_metadata(state, %{request_id: request_id})
      )

    provider_metadata =
      Instrumentation.telemetry_metadata(state, %{request_id: request_id, kind: :turn})

    request = %{
      request
      | context:
          Map.merge(request.context, %{
            route_result_sink: session,
            route_task_supervisor: Sup.task_supervisor(state.supervisor)
          })
    }

    route = provider_route(state)

    task =
      Task.Supervisor.async(Sup.task_supervisor(state.supervisor), fn ->
        OpenTelemetry.with_context(route.id, :turn, request_id, fn ->
          Accounting.run_provider(
            provider,
            route.limiter,
            route.limit_key,
            route.root_session_id,
            request,
            provider_metadata,
            &send(session, {:provider_event, ref, &1})
          )
        end)
      end)

    %{
      state
      | turn: Turn.new(Lemieux.ID.generate()),
        turn_ref: ref,
        current_request_id: request_id,
        provider_progress?: false,
        turn_started_at: turn_started_at,
        first_delta_emitted?: false,
        task: task,
        turns_taken: state.turns_taken + 1,
        request_cost_pending?: true
    }
  end

  def run_compaction_provider(route, provider, request, metadata, request_id) do
    OpenTelemetry.with_context(route.id, :compaction, request_id, fn ->
      Compacting.summarise(
        provider,
        route.limiter,
        route.limit_key,
        route.root_session_id,
        request,
        metadata
      )
    end)
  end

  # What a provider task needs of the session, and nothing else. A closure that
  # named `state` copied the whole session into the task — every entry of the
  # transcript, every request snapshot — once per request, and once per tool
  # call when a wave ran them in parallel.
  def provider_route(state) do
    %{
      id: state.id,
      limiter: state.provider_limiter,
      limit_key: Accounting.provider_limit_key(state),
      root_session_id: state.root_session_id
    }
  end

  def maybe_emit_first_delta(%{first_delta_emitted?: false} = state, event) do
    if provider_progress_event?(event) do
      duration = System.monotonic_time() - state.turn_started_at

      Telemetry.event(
        [:provider, :first_delta],
        %{duration: duration},
        Instrumentation.telemetry_metadata(state, %{entry_id: state.turn.entry_id})
      )

      %{state | first_delta_emitted?: true}
    else
      state
    end
  end

  def maybe_emit_first_delta(state, _event), do: state

  # Output arriving marks the turn as having said something, which decides how a
  # failure is retried. It no longer resets the count: a stream that dies after
  # a few words every time would otherwise be retried forever. A response that
  # completes resets it — see `apply_effect/2`.
  def note_provider_progress(state, event) do
    if provider_progress_event?(event),
      do: %{state | provider_progress?: true},
      else: state
  end

  defp provider_progress_event?({kind, _payload})
       when kind in [:text_delta, :thinking_delta, :tool_call_delta, :tool_call, :message],
       do: true

  defp provider_progress_event?(_event), do: false
end
