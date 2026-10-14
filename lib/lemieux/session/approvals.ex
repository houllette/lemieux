defmodule Lemieux.Session.Approvals do
  @moduledoc false

  alias Lemieux.Approval
  alias Lemieux.Approval.Request
  alias Lemieux.Clock
  alias Lemieux.Contract
  alias Lemieux.Ingress
  alias Lemieux.Messages
  alias Lemieux.Session.Core
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.ToolWave

  def announcement(:approval), do: :tool_approval
  def announcement(:question), do: :question

  def answer_for({:decision, decision}), do: decision
  def answer_for({:answer, text}), do: {:ok, text}

  def resolution_status({:decision, :allow}), do: :allowed
  def resolution_status({:decision, {:rewrite, _arguments}}), do: :rewritten
  def resolution_status({:decision, {:deny, _reason}}), do: :denied
  def resolution_status({:answer, _text}), do: :answered

  def approval_payload(call_id, kind, status, payload) do
    %{
      "call_id" => call_id,
      "kind" => Atom.to_string(kind),
      "status" => Atom.to_string(status),
      "detail" => approval_detail(payload),
      "resolver" => Ingress.audit(Ingress.unknown())
    }
  end

  defp approval_detail(%{name: name, arguments: arguments}),
    do: %{"name" => name, "arguments" => arguments}

  defp approval_detail({:decision, :allow}), do: %{"decision" => "allow"}

  defp approval_detail({:decision, {:deny, reason}}),
    do: %{"decision" => "deny", "reason" => reason}

  defp approval_detail({:decision, {:rewrite, arguments}}),
    do: %{"decision" => "rewrite", "arguments" => arguments}

  defp approval_detail({:answer, text}), do: %{"answer" => text}
  defp approval_detail(%{question: _question} = payload), do: Contract.json(payload)
  defp approval_detail(payload) when is_binary(payload), do: %{"text" => payload}
  defp approval_detail(_payload), do: %{}

  @spec park(
          state :: map(),
          from :: GenServer.from(),
          call_id :: String.t(),
          kind :: atom(),
          payload :: term(),
          opts :: keyword()
        ) :: tuple()
  def park(state, from, call_id, kind, payload, opts) do
    case challenge(state, from, call_id, kind, opts) do
      {:ok, request, timer} ->
        clock_call_id = owner_call_id(state, elem(from, 0)) || call_id

        waiting = %{
          clock_call_id: clock_call_id,
          from: from,
          kind: kind,
          payload: payload,
          timer: timer,
          request: request,
          timeout_reply: Keyword.get(opts, :timeout_reply)
        }

        state =
          state
          |> pause_tool_clock(clock_call_id)
          |> Map.put(:parked, Map.put(state.parked, call_id, waiting))
          |> Core.append({:approval, record(call_id, waiting, :pending, payload), nil})
          |> Core.emit({announcement(kind), payload})
          |> Prompts.observe_attention(%{state: :waiting, call_id: call_id, kind: kind})

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:deny, reason}, state}
    end
  end

  defp challenge(%{approval: %{mode: :scoped}} = state, {caller, _}, call_id, :approval, opts) do
    scope = opts[:approval_scope]

    if owned_tool?(state, caller) and is_binary(scope) and byte_size(scope) == 64 do
      request = Approval.request(state, call_id, scope)

      timer =
        Clock.send_after(
          state.clock,
          self(),
          {:approval_timeout, call_id, request.id},
          state.approval.ttl_ms
        )

      {:ok, request, timer}
    else
      {:error, "scoped approval must bind a live tool action"}
    end
  end

  defp challenge(state, _from, call_id, _kind, _opts),
    do: {:ok, nil, park_timer(state, state.approval_timeout, call_id)}

  defp owner_call_id(state, caller) do
    Enum.find_value(state.wave.tool_tasks, fn {_ref,
                                               {task, call, _stream, _started, _timer,
                                                _descriptor}} ->
      if task.pid == caller, do: call.id
    end)
  end

  defp owned_tool?(state, caller),
    do:
      Enum.any?(state.wave.tool_tasks, fn {_ref,
                                           {task, _call, _stream, _started, _timer, _descriptor}} ->
        task.pid == caller
      end)

  @spec request_for(state :: map(), call_id :: String.t()) ::
          {:ok, Request.t()} | {:error, atom()}
  def request_for(state, call_id) do
    case state.parked[call_id] do
      nil -> {:error, :unknown_call}
      %{request: %Request{} = request} -> {:ok, request}
      _legacy -> {:error, :unscoped_resolution}
    end
  end

  @spec resolve_legacy(state :: map(), call_id :: String.t(), resolution :: term()) :: tuple()
  def resolve_legacy(state, call_id, resolution) do
    case state.parked[call_id] do
      nil ->
        {:reply, {:error, :unknown_call}, state}

      %{request: %Request{}} ->
        {:reply, {:error, :unscoped_resolution}, state}

      waiting ->
        if legacy_valid?(waiting.kind, resolution),
          do:
            resolve(
              state,
              call_id,
              waiting,
              resolution_status(resolution),
              resolution,
              answer_for(resolution)
            ),
          else: {:reply, {:error, :invalid_resolution}, state}
    end
  end

  defp legacy_valid?(:approval, {:decision, :allow}), do: true
  defp legacy_valid?(:approval, {:decision, {:deny, reason}}), do: is_binary(reason)
  defp legacy_valid?(:approval, {:decision, {:rewrite, args}}), do: is_map(args)
  defp legacy_valid?(:question, {:answer, answer}), do: is_binary(answer) or is_map(answer)
  defp legacy_valid?(_kind, _invalid), do: false

  @spec resolve_scoped(
          state :: map(),
          from :: GenServer.from(),
          request :: term(),
          decision :: term(),
          opts :: keyword()
        ) :: tuple()
  def resolve_scoped(state, {caller, _}, %Request{} = request, decision, opts) do
    with {:ok, live} <- request_for(state, request.call_id),
         true <- live == request,
         true <- Clock.now_ms(state.clock) < live.expires_at,
         true <- Approval.valid_decision?(decision),
         {:ok, resolver} <-
           Ingress.attest(state.input.ingress, caller, :approval, opts[:attestation], %{
             request: Approval.audit(live),
             decision: decision_kind(decision)
           }),
         true <- resolver.attested?,
         true <- Clock.now_ms(state.clock) < live.expires_at do
      waiting = Map.put(state.parked[request.call_id], :resolver, resolver)

      resolve(
        state,
        request.call_id,
        waiting,
        decision_status(decision),
        %{},
        scoped_answer(decision, request.scope)
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :stale_approval}, state}
    end
  end

  def resolve_scoped(state, _from, _request, _decision, _opts),
    do: {:reply, {:error, :invalid_resolution}, state}

  defp decision_kind(:allow_once), do: :allow_once
  defp decision_kind({:deny, _reason}), do: :deny
  defp decision_kind({:request_rewrite, _args}), do: :request_rewrite
  defp decision_status(:allow_once), do: :allowed
  defp decision_status({:deny, _reason}), do: :denied
  defp decision_status({:request_rewrite, _args}), do: :rewritten
  defp scoped_answer(:allow_once, scope), do: {:allow_once, scope}
  defp scoped_answer(decision, _scope), do: decision

  defp resolve(state, call_id, waiting, status, resolution, answer) do
    state =
      state
      |> Map.put(:parked, Map.delete(state.parked, call_id))
      |> Core.append({:approval, record(call_id, waiting, status, resolution), nil})
      |> Prompts.observe_working()
      |> release(call_id, waiting, answer)

    {:reply, :ok, state}
  end

  @spec record(call_id :: String.t(), waiting :: map(), status :: atom(), payload :: term()) ::
          map()
  def record(call_id, %{request: %Request{} = request} = waiting, status, _payload) do
    approval_payload(call_id, waiting.kind, status, %{})
    |> Map.put("scope", Approval.audit(request))
    |> Map.put("resolver", Ingress.audit(Map.get(waiting, :resolver, Ingress.unknown())))
  end

  def record(call_id, waiting, status, payload),
    do: approval_payload(call_id, waiting.kind, status, payload)

  @spec expire(state :: map(), call_id :: String.t(), request_id :: String.t()) :: tuple()
  def expire(state, call_id, request_id) do
    case state.parked[call_id] do
      %{request: %Request{id: ^request_id}} = waiting ->
        state =
          state
          |> Map.put(:parked, Map.delete(state.parked, call_id))
          |> Core.append({:approval, record(call_id, waiting, :timed_out, %{}), nil})
          |> Prompts.observe_working()
          |> release(
            call_id,
            waiting,
            timed_out(%{state | approval_timeout: state.approval.ttl_ms}, :approval)
          )

        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def timed_out(state, :approval),
    do: {:deny, Messages.render(state.messages, :approval_timed_out, [state.approval_timeout])}

  def timed_out(state, :question),
    do: {:error, Messages.render(state.messages, :question_timed_out, [state.approval_timeout])}

  def release(state, call_id, waiting, answer) do
    cancel_timer(state, waiting.timer)
    GenServer.reply(waiting.from, answer)
    resume_tool_clock(state, Map.get(waiting, :clock_call_id, call_id))
  end

  def park_timer(_state, :infinity, _call_id), do: nil

  def park_timer(state, timeout, call_id),
    do: Clock.send_after(state.clock, self(), {:park_timeout, call_id}, timeout)

  # A tool's deadline carries when it falls due, because the clock cannot say
  # how much of a cancelled timer was left, and a parked call's deadline is
  # held as exactly that.
  def tool_timer(state, ref, timeout_ms, delay_ms) do
    timer = Clock.send_after(state.clock, self(), {:tool_timeout, ref, timeout_ms}, delay_ms)
    {:timer, timer, Clock.now_ms(state.clock) + delay_ms}
  end

  def cancel_timer(state, {:timer, timer, _due}), do: Clock.cancel(state.clock, timer)
  def cancel_timer(state, timer) when is_reference(timer), do: Clock.cancel(state.clock, timer)
  def cancel_timer(_state, _timer), do: :ok

  # A parked call's tool deadline is held as what was left of it, and started
  # again from there when the call is released. A timer that had already fired
  # cannot be held: its message is on its way, and the call times out as it
  # would have.
  def pause_tool_clock(state, call_id) do
    case tool_task_for(state, call_id) do
      {ref, {task, call, stream_ref, started, {:timer, timer, due}, descriptor}} ->
        case due - Clock.now_ms(state.clock) do
          remaining when remaining > 0 ->
            Clock.cancel(state.clock, timer)

            put_tool_task(
              state,
              ref,
              {task, call, stream_ref, started, {:paused, remaining}, descriptor}
            )

          _due ->
            state
        end

      _not_running ->
        state
    end
  end

  defp resume_tool_clock(state, call_id) do
    case tool_task_for(state, call_id) do
      {ref, {task, call, stream_ref, started, {:paused, remaining}, descriptor}} ->
        timeout_ms = ToolWave.descriptor_timeout(descriptor, state.tool_timeout_ms)
        timer = tool_timer(state, ref, timeout_ms, remaining)
        put_tool_task(state, ref, {task, call, stream_ref, started, timer, descriptor})

      _not_paused ->
        state
    end
  end

  defp tool_task_for(state, call_id) do
    Enum.find(state.wave.tool_tasks, fn {_ref, {_task, call, _stream, _started, _timer, _d}} ->
      call.id == call_id
    end)
  end

  defp put_tool_task(state, ref, tuple),
    do: Core.put_wave(state, :tool_tasks, Map.put(state.wave.tool_tasks, ref, tuple))
end
