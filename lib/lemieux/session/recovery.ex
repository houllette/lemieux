defmodule Lemieux.Session.Recovery do
  @moduledoc false

  require Logger

  alias Lemieux.Clock
  alias Lemieux.Entry
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.Requests
  alias Lemieux.Session.Setup
  alias Lemieux.Session.ToolWave
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Turn

  def drain_steers(%{reversed_steers: []} = state), do: state

  def drain_steers(state) do
    state.reversed_steers
    |> Enum.reverse()
    |> Enum.reduce(%{state | reversed_steers: []}, fn text, state ->
      Core.append(state, {:user, %{"text" => text}, nil})
    end)
  end

  def maybe_follow_up(%{reversed_follow_ups: []} = state), do: state

  def maybe_follow_up(state) do
    [text | rest] = Enum.reverse(state.reversed_follow_ups)

    state
    |> Map.put(:reversed_follow_ups, Enum.reverse(rest))
    |> Prompts.start_follow_up_hook(text)
  end

  def fold(state, event) do
    {turn, effects} = Turn.step(state.turn, event)

    Enum.reduce(effects, %{state | turn: turn}, &ToolWave.apply_effect(&2, &1))
  end

  # The provider stopped without a terminal event. Nothing else will arrive,
  # so the turn is closed here or the session stays busy forever — which is
  # the failure that looks like a hung agent rather than a failed one.
  def close(%{turn: nil} = state, _result), do: state

  def close(%{compaction: %{context_recovery_reason: reason}} = state, _result)
      when not is_nil(reason) do
    begin_context_recovery(state, reason)
  end

  # The failed task returning after its error was already answered with a
  # retry: there is nothing left to close.
  def close(%{provider_retry: %{}} = state, _result), do: state

  def close(state, {:error, reason}) do
    state = Catalog.learn_window(state, reason)

    cond do
      recoverable_context_error?(state, reason) ->
        begin_context_recovery(
          Core.put_compaction(state, :context_recovery_attempted?, true),
          reason
        )

      retryable_now?(state, reason) ->
        begin_provider_retry(state, reason)

      true ->
        fold(state, {:error, reason})
    end
  end

  def close(state, result), do: fold(state, {:error, close_reason(result)})

  defp close_reason(:ok), do: :incomplete_stream
  defp close_reason(other), do: {:unexpected_provider_return, other}

  def recoverable_context_error?(state, reason) do
    state.compaction.auto_compaction? and ProviderError.context_limit?(reason) and
      not state.compaction.context_recovery_attempted? and
      not state.provider_progress? and not Turn.progressed?(state.turn) and compactable?(state)
  end

  defp compactable?(state) do
    case Compacting.compaction_plan(
           state,
           Compacting.sendable(state, Core.behavior_entries(state), Requests.request_opts(state))
         ) do
      {:ok, _plan} -> true
      :nothing_to_do -> false
    end
  end

  defp begin_context_recovery(state, reason) do
    state =
      state
      |> Accounting.account_missing_usage()
      |> Core.put_compaction(:context_recovery_reason, reason)
      |> Core.emit({:context_recovery, %{action: :compact_and_retry, reason: reason}})

    Compacting.start_compacting(state, nil, reason)
  end

  # -- provider retries -------------------------------------------------------

  # A request is sent again when the failure is one the provider may not repeat,
  # the account is not what failed, and the attempts are not used up. Generous,
  # because a gateway once answered a request with a compile error page and an
  # afternoon's tool results ended behind it — and because a person may not be
  # there: `lmx run` in CI has nobody to type `/retry`.
  #
  # A request that had already produced output is retried too. It used to end
  # the turn, on the reasoning that the model might have acted on the half it
  # produced — but nothing it produced has run: tool calls only run once a
  # response is complete (`{:done, _}`), so a partial answer is words and
  # unannounced calls, and nothing in the workspace depends on them. What was
  # said is kept on the transcript as a partial entry for the person who
  # watched it arrive, and the request is answered afresh.
  #
  # The two progress signals are redundant on purpose. `start_turn/1` clears
  # both together and every event that sets one sets the other, so either alone
  # would do — which is exactly why neither should be tidied away. A retry that
  # resent a partial answer as though it were finished is the failure with no
  # evidence in the transcript, so it gets two locks.
  def retryable_now?(%{provider_retry_policy: nil}, _reason), do: false

  def retryable_now?(state, reason) do
    # Quota, billing and authentication failures. Waiting does not refill an
    # account or fix a key, and an exhausted OpenAI quota arrives as a 429
    # that the rate-limit rule would otherwise wait out six times before
    # saying so.
    (not progressed?(state) or state.provider_retry_policy.after_output) and
      state.retry_attempt < state.provider_retry_policy.max_attempts and
      not ProviderError.account?(reason) and
      ProviderError.transient?(reason, state.provider_retry_policy.classify) and
      retry_admitted?(state)
  end

  defp progressed?(state), do: state.provider_progress? or Turn.progressed?(state.turn)

  # Budgets count actual attempts, including retries. Ixway's one-request
  # sessions used to wait out Retry-After only to replace the provider error
  # with an inevitable budget stop. Check before scheduling, including the
  # unknown spend a failed attempt without usage leaves behind. Dispatch still
  # checks the freshly prepared request, since hooks may change its estimate.
  defp retry_admitted?(state) do
    request = state.evidence.current_run.pending_request

    state.turns_taken < state.max_turns and
      Accounting.request_budget(Accounting.account_missing_usage(state), request) == :ok
  end

  def begin_provider_retry(state, reason) do
    after_output? = progressed?(state)
    state = if after_output?, do: checkpoint_partial(state), else: state
    attempt = state.retry_attempt + 1
    delay = retry_delay(state.provider_retry_policy, reason, attempt)
    ref = make_ref()
    timer = Clock.send_after(state.clock, self(), {:provider_retry, ref}, delay)
    category = ProviderError.category(reason)

    Logger.warning(
      "lemieux: provider request failed (#{category}); retrying in #{delay}ms " <>
        "(attempt #{attempt} of #{state.provider_retry_policy.max_attempts}): " <>
        ProviderError.message(reason)
    )

    state
    |> Accounting.account_missing_usage()
    |> Instrumentation.finish_turn_telemetry(:error)
    |> Map.merge(%{
      # The dead task's late events must not reach a turn that is over, and
      # the turn stays so the session reads as busy through the backoff.
      turn_ref: nil,
      provider_retry: %{
        ref: ref,
        timer: timer,
        attempt: attempt,
        delay_ms: delay,
        reason: reason,
        category: category,
        request_id: state.current_request_id
      }
    })
    |> Core.emit(
      {:provider_retry,
       %{
         attempt: attempt,
         max: state.provider_retry_policy.max_attempts,
         delay_ms: delay,
         category: category,
         reason: reason,
         after_output: after_output?
       }}
    )
  end

  # What the model had said when the stream died, written as a record and
  # marked partial so no request sends it again, under the id its deltas were
  # streamed with so a screen can close what it drew. The turn that follows
  # is a fresh one: were the retry refused later, the error would fold into a
  # turn with nothing left to write twice.
  defp checkpoint_partial(%{turn: %Turn{} = turn} = state) do
    state =
      case Turn.checkpoint(turn) do
        nil ->
          state

        {:assistant, payload, usage} ->
          ToolWave.apply_effect(
            state,
            {:append, {:assistant, Turn.partial_payload(payload), usage}}
          )
      end

    %{state | turn: Turn.new(Lemieux.ID.generate()), provider_progress?: false}
  end

  defp checkpoint_partial(state), do: state

  # What the provider asked for, when it said; otherwise a backoff that
  # doubles — 2, 4, 8, 16, 32 seconds — so six attempts ride out a couple of
  # minutes of an overloaded provider, long enough for it to come back, while
  # a blip costs a few seconds.
  defp retry_delay(policy, reason, attempt) do
    (ProviderError.retry_after_ms(reason) ||
       policy.base_delay_ms * Integer.pow(2, attempt - 1))
    |> min(policy.max_delay_ms)
    |> max(0)
  end

  def retry_note(retry) do
    %{
      "attempt" => retry.attempt,
      "after_request_id" => retry.request_id,
      "category" => Atom.to_string(retry.category),
      "reason" => ProviderError.message(retry.reason),
      "delay_ms" => retry.delay_ms
    }
  end

  def retry_policy(false), do: nil

  def retry_policy(opts) when is_list(opts) do
    %{
      max_attempts: Setup.positive_option(opts, :max_attempts, 6),
      base_delay_ms: Setup.positive_option(opts, :base_delay_ms, 2_000),
      max_delay_ms: Setup.positive_option(opts, :max_delay_ms, :timer.minutes(1)),
      after_output: Setup.boolean_option(opts, :after_output, true),
      classify: classifier_option(opts)
    }
  end

  def retry_policy(other),
    do:
      raise(
        ArgumentError,
        "provider_retry must be a keyword list or false, got: #{inspect(other)}"
      )

  defp classifier_option(opts) do
    case Keyword.get(opts, :classify) do
      nil ->
        nil

      classify when is_function(classify, 1) ->
        classify

      other ->
        raise ArgumentError,
              "provider_retry :classify must be a one-argument function, got: #{inspect(other)}"
    end
  end

  # Admission is `{module, ref}` so a host may swap the algorithm and not only
  # the process. A bare pid or name is the older shape and means the shipped
  # limiter; `nil` disables admission.
  def admission_option(opts, supervisor) do
    case Keyword.get(opts, :provider_limiter, :default) do
      :default -> Sup.provider_admission(supervisor)
      nil -> nil
      {module, ref} when is_atom(module) -> {module, ref}
      ref when is_pid(ref) or is_atom(ref) -> {Lemieux.ProviderLimiter, ref}
    end
  end

  # The last thing the conversation did was fail on the provider's side.
  # A turn budget or a cancellation also ends in an entry, but not one that
  # sending the request again would change.
  def retryable_stop?(state) do
    case Enum.find(
           state.reversed_entries,
           &(&1.type in [:user, :assistant, :tool_result, :error, :cancelled])
         ) do
      %Entry{type: :error, payload: %{"category" => _category}} -> true
      _other -> false
    end
  end
end
