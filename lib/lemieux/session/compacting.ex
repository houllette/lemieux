defmodule Lemieux.Session.Compacting do
  @moduledoc false

  require Logger

  alias Lemieux.Clock
  alias Lemieux.Compaction
  alias Lemieux.Compaction.Price
  alias Lemieux.Context
  alias Lemieux.Context.Forecast
  alias Lemieux.Messages
  alias Lemieux.ModelSpec
  alias Lemieux.Provider
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Requests
  alias Lemieux.Session.Window
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Telemetry
  alias Lemieux.Usage

  # A summary's output budget. It was 4,096, which a reasoning model at high
  # effort spent entirely on reasoning, so the summary stopped at its length
  # limit and compaction turned itself off. The summarising request now asks
  # for low effort as well; the cap only bounds an explicit host maximum.
  @summary_max_tokens 8_192
  @summary_max_tokens_cap 16_384
  @summary_retry_delay_ms 2_000

  # The prepared request, including host hook changes, is the only truthful
  # input to an admission decision. Compaction still runs between turns.
  def continue(state), do: Requests.start_turn(state)

  def due?(%{compaction: %{auto_compaction?: false}}, _request), do: false
  # After a failed summary the threshold waits out a backoff counted in
  # requests. It used to stop for the rest of the session, so one gateway
  # hiccup during a summary left a long session to run into the provider's
  # own limit with nothing standing in the way.
  def due?(%{compaction: %{retry_at: at}, request_count: count}, _request)
      when is_integer(at) and count < at,
      do: false

  def due?(%{compaction: %{preflight_attempted?: true}}, _request), do: false

  def due?(state, request) do
    forecast = forecast(state, request)

    cond do
      threshold_due?(state, forecast.input_tokens) ->
        {:threshold, %{input_tokens: forecast.input_tokens, source: forecast.source}}

      decision = price_due?(state, request, forecast.input_tokens) ->
        decision

      advice_due?(state, request) ->
        {:advice, state.compaction.advice}

      true ->
        false
    end
  end

  def valid_compaction_advice?(
        %{
          model: model,
          reason: reason,
          expires_at: %DateTime{} = expires_at
        } = advice
      )
      when is_binary(model) and reason in [:cost, :logical] do
    target = Map.get(advice, :keep_recent_tokens)
    scope = Map.get(advice, :scope)

    DateTime.compare(expires_at, DateTime.utc_now()) == :gt and
      (is_nil(target) or (is_integer(target) and target > 0)) and
      (is_nil(scope) or (is_binary(scope) and scope != ""))
  end

  def valid_compaction_advice?(_advice), do: false

  defp advice_due?(%{compaction: %{advice: advice}}, request) when is_map(advice) do
    advice.model == request.model and
      DateTime.compare(advice.expires_at, DateTime.utc_now()) == :gt and
      (is_nil(Map.get(advice, :scope)) or
         Map.get(request.context, "compaction_scope") == advice.scope)
  end

  defp advice_due?(_state, _request), do: false

  def prune_advice(%{compaction: %{advice: advice}} = state, request) when is_map(advice) do
    if advice_due?(state, request),
      do: state,
      else: Core.put_compaction(state, :advice, nil)
  end

  def prune_advice(state, _request), do: state

  defp forecast(state, request),
    do:
      Forecast.input(request, Core.entries(state), counter: state.compaction.input_token_counter)

  # A session whose own instructions and tools forecast past the threshold
  # cannot be brought under it by summarising the conversation, so it is not
  # tried: on a 4,096-token window lmx's system prompt and nine tools are
  # already over 0.8 of it, and it summarised every third request until a
  # request budget stopped the run with no answer. The person is told about
  # a window that small once (`Lemieux.Session.Window`).
  defp threshold_due?(state, tokens) do
    case threshold(state) do
      nil -> false
      threshold -> tokens >= threshold and Window.overhead(state) < threshold
    end
  end

  defp threshold(%{compaction: %{compact_at: at}} = state) when is_number(at) do
    case effective_window(state) do
      nil -> nil
      window -> window * at
    end
  end

  defp threshold(_state), do: nil

  # Set by an automatic compaction, settled by the request built after it. If
  # that request is still over the threshold the summary made no room, and
  # summarising again would make none either; the threshold backs off and
  # the session says so, rather than paying for a summary every few requests
  # on a window its own instructions nearly fill. Measured on a 4,096-token
  # window: two summaries in eight requests and no answer.
  def verify_room(%{compaction: %{verify_room?: true}} = state, request) do
    state = Core.put_compaction(state, :verify_room?, false)
    tokens = forecast(state, request).input_tokens

    case threshold(state) do
      threshold when is_number(threshold) and tokens >= threshold ->
        state = Core.back_off_ineffective_compaction(state)

        Core.emit(
          state,
          {:compaction_ineffective,
           %{
             input_tokens: tokens,
             threshold: round(threshold),
             window: effective_window(state),
             retry_in: state.compaction.retry_at - state.request_count
           }}
        )

      _room ->
        state
    end
  end

  def verify_room(state, _request), do: state

  defp price_due?(%{compaction: %{price_tiers: prices}} = state, request, before)
       when map_size(prices) > 0 do
    sendable = sendable(state, Core.behavior_entries(state), Requests.request_opts(state))

    case compaction_plan(state, sendable) do
      {:ok, plan} ->
        after_bytes = Request.input_bytes(%{request | entries: plan.tail})
        before_bytes = Request.input_bytes(request)
        summary_output = 4096
        after_tokens = round(before * after_bytes / before_bytes) + summary_output

        summary_input =
          %Request{
            model: state.compaction.summary_model || request.model,
            system:
              compaction_instructions(
                state,
                compaction_summary(state, Core.behavior_entries(state))
              ),
            entries: Compaction.summarising(plan.elder),
            tools: [],
            params: summary_params(state)
          }
          |> Request.input_bytes()
          |> then(&max(div(&1 + 3, 4), 1))

        opts = [
          model: request.model,
          summary_model: state.compaction.summary_model || request.model,
          expected_output_tokens: state.compaction.price_expected_output_tokens,
          cached_input_tokens: context(state).current.cached,
          minimum_savings_usd: state.compaction.price_minimum_savings_usd
        ]

        case Price.evaluate(
               before,
               after_tokens,
               summary_input,
               summary_output,
               prices,
               opts
             ) do
          {:compact, economics} -> {:price, economics}
          :continue -> false
        end

      :nothing_to_do ->
        false
    end
  end

  defp price_due?(_state, _request, _tokens), do: false

  def context(state), do: Context.position(Core.entries(state), window: Window.known(state))

  # Returns the state with a summarising task running, or `nil` when there is
  # nothing worth cutting — which lets `continue/1` fall through to the turn
  # rather than having two ways to say "carry on".
  def start_compacting(state, from), do: start_compacting(state, from, nil)

  def start_compacting(state, from, recovery_reason) do
    sendable = sendable(state, Core.behavior_entries(state), Requests.request_opts(state))

    case compaction_plan(state, sendable) do
      {:ok, plan} -> start_compaction(state, plan, from, recovery_reason)
      :nothing_to_do -> nothing_to_compact(state, from)
    end
  end

  # -- the compaction seam ----------------------------------------------------
  #
  # Every call the loop makes into compaction goes through these, so a host's
  # `:compaction` module sees all of them and the shipped default sees the same
  # ones. What stays above and below is the trigger: *when* to summarise is the
  # loop's, because only it knows it is between turns.

  def compaction_plan(state, entries) do
    {module, cstate} = state.compaction.strategy
    module.plan(cstate, entries, plan_opts(state))
  end

  # `:keep` travels only when a host set it, so its default lives in one
  # place — `Lemieux.Compaction.plan/2` — and a replacement chooses its own.
  #
  # The capped window travels always, as information: with nothing else set,
  # the shipped plan turns it into a token target. The count-based rule that
  # was the only default could cut only at a later `:user` entry, so one
  # prompt followed by a long run of tool calls — the session somebody leaves
  # to fix a test suite — could not be compacted at all, and ended when the
  # provider refused it.
  defp plan_opts(state) do
    target =
      case {state.compaction.advice, state.compaction.keep_recent_tokens, state.compaction.keep,
            state.compaction.price_tiers} do
        {%{keep_recent_tokens: value}, _configured, _keep, _prices} when is_integer(value) ->
          value

        {_advice, nil, nil, prices} when map_size(prices) > 0 ->
          20_000

        {_advice, value, _keep, _prices} ->
          value
      end

    [keep: state.compaction.keep, keep_recent_tokens: target, window: effective_window(state)]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The window compaction plans against: the model's own, or the fallback when
  # nobody knows it, and never more than the cap. Only the trigger and the
  # retained tail use this; a status line still reports the model's real window.
  defp effective_window(state), do: Window.planning(state)

  def sendable(state, entries, opts \\ []) do
    {module, cstate} = state.compaction.strategy
    module.applied(cstate, entries, opts)
  end

  defp conversation?(state, entries) do
    {module, cstate} = state.compaction.strategy
    module.conversation?(cstate, entries)
  end

  defp compaction_summary(state, entries) do
    {module, cstate} = state.compaction.strategy
    module.summary(cstate, entries)
  end

  defp compaction_sections(state, summary) do
    {module, cstate} = state.compaction.strategy
    module.sections(cstate, summary)
  end

  defp compaction_instructions(state, previous) do
    {module, cstate} = state.compaction.strategy
    module.instructions(cstate, previous, sections: state.compaction.summary_sections)
  end

  def with_summary(state, entries) do
    {module, cstate} = state.compaction.strategy
    module.with_summary(cstate, state.system, compaction_summary(state, entries))
  end

  # The cut point is the newest entry on the transcript rather than the newest
  # *sendable* one, so the compaction this writes also supersedes any earlier
  # one — otherwise clearing twice would leave the first summary in the system
  # prompt and the session would not be clear at all.
  def clear_context(state) do
    entries = Core.behavior_entries(state)

    if conversation?(state, entries) do
      {:reply, {:ok, %{entries: length(sendable(state, entries))}}, cut(state, entries)}
    else
      {:reply, {:error, :nothing_to_do}, state}
    end
  end

  defp cut(state, entries) do
    sendable = sendable(state, entries)

    payload = %{
      "summary" => nil,
      "from" => sendable |> List.first() |> Map.fetch!(:id),
      "to" => entries |> List.last() |> Map.fetch!(:id),
      "entries" => length(sendable),
      "request_id" => nil
    }

    state
    |> Core.put_compaction(:compaction_failed?, false)
    |> Core.forget_compaction_failures()
    |> Core.append({:compaction, payload, nil})
    |> Core.emit({:cleared, %{entries: length(sendable)}})
    # A cut makes the position unmeasured — `Lemieux.Context` says why — and that is
    # exactly what a status line exists to show. Without this, clearing said it had
    # cleared the conversation while the footer went on reporting the window it had
    # just emptied.
    |> then(&Core.emit(&1, {:context, context(&1)}))
  end

  defp nothing_to_compact(_state, nil), do: nil

  defp nothing_to_compact(state, from) do
    GenServer.reply(from, {:error, :nothing_to_do})

    {:noreply, state}
  end

  defp start_compaction(state, plan, from, recovery_reason, attempt \\ 1) do
    request = %Request{
      model: state.compaction.summary_model || state.model,
      system:
        compaction_instructions(state, compaction_summary(state, Core.behavior_entries(state))),
      entries: Compaction.summarising(plan.elder),
      # No tools: the summariser is writing, not working, and a tool call in
      # the middle of it would be a call nobody is going to run.
      tools: [],
      params: summary_params(state),
      output_schema: nil
    }

    state = state |> Core.put_compaction(:advice, nil) |> Audit.prepare_harness_snapshot(request)

    case Accounting.request_budget(state, request) do
      :ok ->
        provider = state.provider

        state =
          if state.compaction.forecast do
            Core.emit(
              state,
              {:compaction_planned,
               %{trigger: state.compaction.trigger, forecast: state.compaction.forecast}}
            )
          else
            state
          end

        request_snapshot =
          RequestSnapshot.build(request, Audit.request_snapshot_opts(state, kind: :compaction))

        state = Core.append(state, {:request, request_snapshot, nil})
        request_id = RequestSnapshot.id(request_snapshot)

        compaction_started_at =
          Telemetry.start(
            [:compaction],
            Instrumentation.telemetry_metadata(state, %{
              request_id: request_id,
              kind: Instrumentation.recovery_kind(recovery_reason)
            })
          )

        provider_metadata =
          Instrumentation.telemetry_metadata(state, %{request_id: request_id, kind: :compaction})

        route = Requests.provider_route(state)

        task =
          Task.Supervisor.async(Sup.task_supervisor(state.supervisor), fn ->
            Requests.run_compaction_provider(
              route,
              provider,
              request,
              provider_metadata,
              request_id
            )
          end)

        compacting = %{
          task: task,
          plan: plan,
          from: from,
          request_id: request_id,
          recovery_reason: recovery_reason,
          trigger: state.compaction.trigger || compaction_trigger(from, recovery_reason),
          started_at: compaction_started_at,
          attempt: attempt,
          retry: nil
        }

        state =
          state
          |> Core.put_compaction(:trigger, nil)
          |> Core.put_compaction(:forecast, nil)
          |> Core.put_compaction(:compacting, compacting)
          |> Map.put(:request_cost_pending?, true)

        if from, do: {:noreply, state}, else: state

      {:error, payload} when is_nil(from) ->
        Accounting.budget_stop(state, payload)

      {:error, payload} ->
        GenServer.reply(from, {:error, {:budget, payload}})
        {:noreply, state}
    end
  end

  defp compaction_trigger(from, _recovery_reason) when not is_nil(from), do: :manual
  defp compaction_trigger(_from, recovery_reason) when not is_nil(recovery_reason), do: :overflow
  defp compaction_trigger(_from, _recovery_reason), do: :threshold

  # A summary waiting out its retry has no task and no running telemetry: its
  # failed attempt was accounted when it failed.
  def cancel_compacting(_state, nil), do: :ok

  def cancel_compacting(state, %{task: nil, retry: %{timer: timer}} = compacting) do
    Clock.cancel(state.clock, timer)
    reply_compacting_cancelled(compacting)
  end

  def cancel_compacting(state, compacting) do
    Telemetry.stop(
      [:compaction],
      compacting.started_at,
      Instrumentation.telemetry_metadata(state, %{
        request_id: compacting.request_id,
        kind: Instrumentation.recovery_kind(compacting.recovery_reason),
        outcome: :cancelled
      })
    )

    Task.shutdown(compacting.task, 0)
    reply_compacting_cancelled(compacting)
  end

  def cancel_mcp_wait(state, %{timer: timer}) when is_reference(timer),
    do: Clock.cancel(state.clock, timer)

  def cancel_mcp_wait(_state, _wait), do: :ok

  defp reply_compacting_cancelled(%{from: nil}), do: :ok
  defp reply_compacting_cancelled(%{from: from}), do: GenServer.reply(from, {:error, :cancelled})

  def finish_compacting(state, result) do
    case summary_retry(state, result) do
      {:retry, state} -> state
      :no_retry -> state |> compaction_finished(result) |> after_compaction()
    end
  end

  # One more attempt, for a failure the provider may not repeat, when the host
  # has not turned retries off. A summariser that stopped at its length limit
  # or wrote nothing would do the same again, so those are not retried.
  defp summary_retry(
         %{provider_retry_policy: policy, compaction: %{compacting: %{attempt: 1} = compacting}} =
           state,
         {_outcome, _events} = result
       )
       when is_map(policy) do
    reason = summary_failure(result)

    if not is_nil(reason) and ProviderError.transient?(reason, policy.classify),
      do: {:retry, schedule_summary_retry(state, compacting, result, reason)},
      else: :no_retry
  end

  defp summary_retry(_state, _result), do: :no_retry

  defp summary_failure({:crashed, _reason}), do: nil

  defp summary_failure({outcome, events}) do
    case {emitted_error(events), outcome} do
      {nil, {:error, reason}} -> reason
      {reason, _outcome} -> reason
    end
  end

  defp schedule_summary_retry(state, compacting, result, reason) do
    request_id = compacting.request_id

    delay =
      min(ProviderError.retry_after_ms(reason) || @summary_retry_delay_ms, :timer.minutes(1))

    Logger.warning(
      "lemieux: summarising session #{state.id} failed (#{ProviderError.category(reason)}); " <>
        "retrying in #{delay}ms: " <> ProviderError.message(reason)
    )

    state =
      state
      |> emit_compaction_metadata(result, request_id)
      |> Accounting.account_compaction(result)
      |> Core.append(
        {:error,
         %{
           "reason" => "compaction failed",
           "request_id" => request_id,
           "trigger" => Atom.to_string(compacting.trigger),
           "retrying" => true
         }, summary_error_usage(state, result, request_id)}
      )

    Telemetry.stop(
      [:compaction],
      compacting.started_at,
      Instrumentation.telemetry_metadata(state, %{
        request_id: request_id,
        kind: Instrumentation.recovery_kind(compacting.recovery_reason),
        outcome: :error
      })
    )

    ref = make_ref()
    timer = Clock.send_after(state.clock, self(), {:compaction_retry, ref}, delay)

    Core.put_compaction(state, :compacting, %{
      compacting
      | task: nil,
        retry: %{ref: ref, timer: timer}
    })
  end

  def resume_compaction(state, compacting) do
    case start_compaction(
           state,
           compacting.plan,
           compacting.from,
           compacting.recovery_reason,
           compacting.attempt + 1
         ) do
      {:noreply, state} -> state
      state -> state
    end
  end

  # A summary is writing, not reasoning, and it has a budget. It used to inherit
  # the session's effort with a 4,096-token cap, which a reasoning model at high
  # effort spent on thinking before it wrote a word; the request stopped at its
  # length limit, and that one failure turned compaction off for the session.
  # Low effort where the model offers it, and a larger budget, unless the host
  # said otherwise in `:summary_params`.
  defp summary_params(state) do
    explicit = state.compaction.summary_params
    model = state.compaction.summary_model || state.model

    state.params
    |> Keyword.merge(explicit)
    |> summary_effort(explicit, Provider.reasoning_efforts(state.provider, model))
    |> Keyword.put(:max_tokens, summary_max_tokens(state.params, explicit))
    |> summary_cache(model)
  end

  # A summary's system prompt is not the turn's, so the prefix it would cache
  # is one no later request reads, and Anthropic bills the write at a quarter
  # over the input price. Only for Anthropic's own models: the option is
  # theirs, and another provider refuses it as unknown.
  defp summary_cache(params, model) do
    if ModelSpec.provider(model) == "anthropic",
      do: Keyword.put_new(params, :anthropic_prompt_cache, false),
      else: params
  end

  defp summary_effort(params, explicit, efforts) do
    cond do
      Keyword.has_key?(explicit, :reasoning_effort) -> params
      "low" in efforts -> Keyword.put(params, :reasoning_effort, "low")
      "minimal" in efforts -> Keyword.put(params, :reasoning_effort, "minimal")
      true -> params
    end
  end

  defp summary_max_tokens(params, explicit) do
    case {Keyword.get(explicit, :max_tokens), Keyword.get(params, :max_tokens)} do
      {count, _session} when is_integer(count) and count > 0 ->
        count

      {_summary, count} when is_integer(count) and count > 0 ->
        min(count, @summary_max_tokens_cap)

      _unset ->
        @summary_max_tokens
    end
  end

  # Run inside the task, so the events arrive in this process's own mailbox and
  # can be drained in order once the request is over. An accumulator would need
  # somewhere mutable to live; the mailbox already is that, and messages a
  # process sends itself keep their order.
  def summarise(provider, limiter, limit_key, root_session_id, request, provider_metadata) do
    me = self()

    outcome =
      Accounting.run_provider(
        provider,
        limiter,
        limit_key,
        root_session_id,
        request,
        provider_metadata,
        fn event ->
          send(me, {:summary_event, event})
        end
      )

    {outcome, drain_summary([])}
  end

  defp drain_summary(events) do
    receive do
      {:summary_event, event} -> drain_summary([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  # The assembled message wins over the deltas for the same reason it does in
  # `Lemieux.Turn`: it is what the provider actually produced.
  defp summary_text(events) do
    case Enum.find(events, &match?({:message, _payload}, &1)) do
      {:message, payload} ->
        text_of(payload)

      nil ->
        events |> Enum.filter(&match?({:text_delta, _text}, &1)) |> Enum.map_join(&elem(&1, 1))
    end
  end

  defp text_of(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join(&Map.get(&1, "text", ""))
  end

  defp text_of(_payload), do: ""

  def compaction_finished(state, result) do
    %{
      plan: plan,
      from: from,
      request_id: request_id,
      recovery_reason: recovery_reason,
      trigger: trigger,
      started_at: started_at
    } = state.compaction.compacting

    state =
      state
      |> emit_compaction_metadata(result, request_id)
      |> Core.put_compaction(:compacting, nil)
      |> Accounting.account_compaction(result)

    state =
      case summary_outcome(state, result) do
        {:ok, summary, usage} -> compacted(state, plan, summary, usage, from, request_id, trigger)
        {:error, reason} -> compaction_failed(state, reason, from, result, request_id, trigger)
      end

    Telemetry.stop(
      [:compaction],
      started_at,
      Instrumentation.telemetry_metadata(state, %{
        request_id: request_id,
        kind: Instrumentation.recovery_kind(recovery_reason),
        outcome: if(state.compaction.compaction_failed?, do: :error, else: :ok)
      })
    )

    {state, from, recovery_reason}
  end

  defp emit_compaction_metadata(state, {:crashed, _reason}, _request_id), do: state

  defp emit_compaction_metadata(state, {_outcome, events}, request_id) do
    Enum.reduce(events, state, fn
      {:response_metadata, metadata}, state ->
        Core.emit(state, {:response_metadata, Map.put(metadata, :request_id, request_id)})

      _event, state ->
        state
    end)
  end

  # A summarising request can fail three ways and all three land here: the
  # provider returned an error, it emitted one as its last event, or the task
  # running it died. An empty answer counts too — a compaction entry with no
  # summary in it would cut the conversation and replace it with nothing.
  defp summary_outcome(_state, {:crashed, reason}), do: {:error, describe(reason)}

  defp summary_outcome(state, {outcome, events}) do
    case {emitted_error(events), outcome} do
      {nil, :ok} ->
        with :ok <- complete_summary(events),
             {:ok, text} <- text_or_nothing(state, summary_text(events)),
             :ok <- summary_size(state, text) do
          {:ok, text, summary_usage(events)}
        end

      {nil, {:error, reason}} ->
        {:error, describe(reason)}

      {reason, _outcome} ->
        {:error, describe(reason)}
    end
  end

  defp complete_summary(events) do
    case List.last(events) do
      {:done, :stop} ->
        if Enum.any?(events, &match?({:tool_call, _}, &1)),
          do: {:error, "summariser attempted a tool call"},
          else: :ok

      {:done, reason} ->
        {:error, "summariser stopped with #{inspect(reason)}"}

      _other ->
        {:error, "summariser did not finish"}
    end
  end

  defp summary_size(state, text) do
    if byte_size(text) <= state.compaction.summary_max_bytes,
      do: :ok,
      else: {:error, "summariser exceeded summary_max_bytes"}
  end

  def summary_usage(events) do
    Enum.find_value(Enum.reverse(events), %{}, fn
      {:usage, usage} when is_map(usage) -> usage
      _event -> nil
    end)
  end

  defp emitted_error(events) do
    Enum.find_value(events, fn
      {:error, reason} -> reason
      _event -> nil
    end)
  end

  defp text_or_nothing(state, ""),
    do: {:error, Messages.render(state.messages, :summary_empty, [])}

  defp text_or_nothing(_state, text), do: {:ok, text}

  # An explicit `compact/2` leaves the session idle: whoever asked for it was
  # not waiting for a turn. A threshold compaction is standing in front of one,
  # so the turn goes ahead.
  def after_compaction({state, nil, nil}), do: Requests.start_turn(state)

  def after_compaction({%{compaction: %{compaction_failed?: true}} = state, nil, recovery_reason}) do
    state
    |> Core.put_compaction(:context_recovery_reason, nil)
    |> Recovery.fold({:error, recovery_reason})
  end

  def after_compaction({state, nil, _recovery_reason}) do
    state
    |> Core.put_compaction(:context_recovery_reason, nil)
    |> Requests.start_turn()
  end

  def after_compaction({state, _from, _recovery_reason}), do: state

  defp compacted(state, plan, summary, provider_usage, from, request_id, trigger) do
    # Read back only when asked for: a summary nobody asked to structure
    # that happens to contain a `Decisions` heading is prose.
    sections = if state.compaction.summary_sections, do: compaction_sections(state, summary)

    # Measured here because it is the last moment it can be: appending the entry
    # below makes the position unmeasured until the next response. An entry count
    # says how much transcript went; the reason to compact is the window.
    tokens = Context.compacted(context(state), Core.entries(state), plan.elder, summary)

    payload = %{
      "summary" => summary,
      "from" => plan.elder |> List.first() |> Map.fetch!(:id),
      "to" => plan.elder |> List.last() |> Map.fetch!(:id),
      "entries" => length(plan.elder),
      "request_id" => request_id,
      "trigger" => Atom.to_string(trigger),
      "sections" =>
        sections && Map.new(sections, fn {key, items} -> {Atom.to_string(key), items} end)
    }

    usage =
      provider_usage
      |> Usage.normalize(state.compaction.summary_model || state.model)
      |> Map.put("request_id", request_id)

    state =
      state
      |> Core.put_compaction(:compaction_failed?, false)
      |> Core.forget_compaction_failures()
      # Only one the loop started itself is checked: a request follows it
      # at once. After an explicit `compact/2` the session goes idle.
      |> Core.put_compaction(:verify_room?, is_nil(from))
      |> Core.append({:compaction, payload, usage})
      |> Core.emit(
        {:compacted,
         %{
           summary: summary,
           entries: Enum.map(plan.elder, & &1.id),
           sections: sections,
           tokens: tokens,
           usage: usage,
           trigger: trigger
         }}
      )

    if from, do: GenServer.reply(from, {:ok, %{summary: summary, entries: length(plan.elder)}})

    state
  end

  # The conversation is untouched, which is the whole point: a summariser that
  # failed must not cost anybody their history. The turn goes ahead with the
  # full conversation, and will usually work — the threshold fires well before
  # the window is actually full.
  defp compaction_failed(state, reason, from, result, request_id, trigger) do
    Logger.warning("lemieux: could not summarise session #{state.id}: #{reason}")

    usage = summary_error_usage(state, result, request_id)

    state =
      Core.append(
        state,
        {:error,
         %{
           "reason" => "compaction failed",
           "request_id" => request_id,
           "trigger" => Atom.to_string(trigger)
         }, usage}
      )

    state =
      state
      |> Core.put_compaction(:compaction_failed?, true)
      |> Core.back_off_compaction()
      |> Core.emit({:compaction_failed, reason})

    if from, do: GenServer.reply(from, {:error, reason})

    state
  end

  defp summary_error_usage(_state, {:crashed, _reason}, _request_id), do: nil

  defp summary_error_usage(state, {_outcome, events}, request_id) do
    case summary_usage(events) do
      usage when map_size(usage) > 0 ->
        usage
        |> Usage.normalize(state.compaction.summary_model || state.model)
        |> Map.put("request_id", request_id)

      _missing ->
        nil
    end
  end

  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)
end
