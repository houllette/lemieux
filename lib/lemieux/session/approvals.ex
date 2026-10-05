defmodule Lemieux.Session.Approvals do
  @moduledoc false

  alias Lemieux.Clock
  alias Lemieux.Contract
  alias Lemieux.Messages
  alias Lemieux.Session.Core
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
      "detail" => approval_detail(payload)
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

  def timed_out(state, :approval),
    do: {:deny, Messages.render(state.messages, :approval_timed_out, [state.approval_timeout])}

  def timed_out(state, :question),
    do: {:error, Messages.render(state.messages, :question_timed_out, [state.approval_timeout])}

  def release(state, call_id, waiting, answer) do
    cancel_timer(state, waiting.timer)
    GenServer.reply(waiting.from, answer)
    resume_tool_clock(state, call_id)
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
