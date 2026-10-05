defmodule Lemieux.Session.ToolWave do
  @moduledoc false

  alias Lemieux.Hooks
  alias Lemieux.Messages
  alias Lemieux.OpenTelemetry
  alias Lemieux.Provider
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Aside
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Prompts
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Telemetry
  alias Lemieux.Tool
  alias Lemieux.Tool.Attachment
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Receipt
  alias Lemieux.Tools
  alias Lemieux.Turn

  # How many recent tool calls the session remembers for the guard. Long
  # enough to hold three rounds of an alternating pair, short enough that the
  # calls of an hour ago say nothing about now. The record is the session's;
  # the rule read off it is `Lemieux.Session.Guard`'s.
  @recent_calls 8

  # `structured_content` with a `"status"` of one of these, as `bash` reports a
  # background task, or `metadata` saying `"in_progress" => true`, which is how
  # any other tool can say the same.
  @in_progress ~w(running pending queued in_progress)

  def apply_effect(state, {:emit, {:error, reason} = event}) do
    hooks = state.hooks
    context = Prompts.hook_context(state)

    state
    |> Core.emit(event)
    |> Prompts.observe_async(fn -> Hooks.error(hooks, reason, context) end)
  end

  def apply_effect(state, {:emit, event}), do: Core.emit(state, event)

  def apply_effect(state, {:append, {:assistant, payload, usage}}) do
    payload = Map.put(payload, "request_id", state.current_request_id)
    Core.append(state, {:assistant, payload, usage}, id: state.turn.entry_id)
  end

  def apply_effect(state, {:append, {:error, payload, usage}}) do
    payload = Map.put(payload, "request_id", state.current_request_id)
    Core.append(state, {:error, payload, usage})
  end

  def apply_effect(state, {:append, entry_spec}), do: Core.append(state, entry_spec)

  # No tool was offered, so a call is the model's invention; it is answered
  # with a denial rather than run, and the aside ends there.
  def apply_effect(%{aside: %Aside{}} = state, {:run_tools, calls}) do
    state =
      Enum.reduce(calls, state, fn call, acc ->
        Core.append(
          acc,
          {:tool_result,
           %{
             "call_id" => call.id,
             "name" => call.name,
             "error" => true,
             "outcome" => "denied",
             "output" => Messages.render(acc.messages, :aside_denied, [call])
           }, nil}
        )
      end)

    apply_effect(state, {:finished, :error})
  end

  def apply_effect(state, {:run_tools, calls}) do
    state
    |> Instrumentation.finish_turn_telemetry(:tool_calls)
    |> Accounting.account_missing_usage()
    |> Map.merge(%{turn: nil, turn_ref: nil, current_request_id: nil, retry_attempt: 0})
    |> run_tools(calls)
  end

  def apply_effect(state, {:finished, stop_reason}) do
    state =
      state
      |> Instrumentation.finish_turn_telemetry(stop_reason)
      |> Accounting.account_missing_usage()
      |> Map.merge(%{turn: nil, turn_ref: nil, current_request_id: nil})
      |> then(&if(stop_reason == :error, do: &1, else: %{&1 | retry_attempt: 0}))

    # Something was said while the model was answering, and the model has now
    # stopped. Going idle here would leave those words in the queue until somebody
    # prompted again, which reads as having been ignored. The bound still applies: a
    # steer cannot buy more turns than the prompt was allowed.
    if is_nil(state.aside) and state.reversed_steers != [] and
         state.turns_taken < state.max_turns do
      Compacting.continue(state)
    else
      state =
        if state.turns_taken >= state.max_turns,
          do: %{state | reversed_steers: []},
          else: state

      Prompts.start_stop_hook(state, stop_reason)
    end
  end

  # A wave runs in two phases: everything that might write goes first and one at a
  # time, then everything that promised it touches nothing goes at once.
  #
  # Running the whole wave at once silently lost work — two `edit` calls on one
  # file both read it, both wrote it, and the first edit was gone with nothing in
  # the transcript to say so. The model's own order is the only ordering it could
  # have meant. The readers wait rather than going alongside, because a `read` that
  # overlaps an `edit` of the same file returns a file that never existed.
  defp run_tools(state, calls) do
    wave = %{
      state.wave
      | tool_tasks: %{},
        tool_results: %{},
        tool_receipts: %{},
        tool_order: Enum.map(calls, & &1.id),
        tool_batches: tool_batches(state, calls)
    }

    start_tools(%{state | wave: wave})
  end

  # Calls that declare a resource key may overlap other keys, but calls for
  # the same resource stay ordered. An exclusive call remains a barrier. The
  # final parallel batch contains only tools that promised they touch nothing,
  # preserving the older writers-before-readers guarantee.
  defp tool_batches(state, calls) do
    {parallel, governed} = Enum.split_with(calls, &(concurrency(state, &1) == :parallel))
    batches = resource_batches(state, governed, [], [], MapSet.new())

    if parallel == [], do: batches, else: batches ++ [parallel]
  end

  defp resource_batches(_state, [], batches, [], _keys), do: batches

  defp resource_batches(_state, [], batches, current, _keys),
    do: batches ++ [Enum.reverse(current)]

  defp resource_batches(state, [call | rest], batches, current, keys) do
    case concurrency(state, call) do
      :exclusive ->
        batches = append_batch(batches, current) ++ [[call]]
        resource_batches(state, rest, batches, [], MapSet.new())

      {:resource, key} ->
        if MapSet.member?(keys, key) do
          batches = append_batch(batches, current)
          resource_batches(state, rest, batches, [call], MapSet.new([key]))
        else
          resource_batches(state, rest, batches, [call | current], MapSet.put(keys, key))
        end
    end
  end

  defp append_batch(batches, []), do: batches
  defp append_batch(batches, reversed), do: batches ++ [Enum.reverse(reversed)]

  # An unknown name is safe to answer alongside readers: `Tools.run/4` turns
  # it into an unavailable result without executing anything.
  defp concurrency(state, call) do
    case Tool.fetch(state.tools, call.name) do
      {:ok, tool} -> tool |> Tool.descriptor() |> Descriptor.concurrency()
      :error -> :parallel
    end
  end

  defp start_tools(%{wave: %{tool_batches: []}} = state), do: tools_done(state)

  defp start_tools(%{wave: %{tool_batches: [calls | rest]}} = state) do
    {planned, _reserved} =
      Enum.map_reduce(calls, 0.0, fn call, reserved ->
        case tool_budget(state, call, reserved) do
          {:ok, estimate} -> {{call, :ok}, reserved + estimate}
          {:error, payload} -> {{call, {:error, payload}}, reserved}
        end
      end)

    tasks = Enum.reduce(planned, %{}, &Map.merge(&2, start_tool(state, &1)))

    %{state | wave: %{state.wave | tool_batches: rest, tool_tasks: tasks}}
  end

  defp start_tool(state, {call, budget}) do
    # Outside the closure: inside it, `self()` is the task, and a tool that
    # parked itself would call its own process and exit.
    session = self()
    descriptor = call_descriptor(state, call)
    timeout_ms = descriptor_timeout(descriptor, state.tool_timeout_ms)
    context = tool_context(state, call, session, timeout_ms)
    stream_ref = make_ref()
    started = System.monotonic_time(:millisecond)

    Telemetry.start(
      [:tool, :call],
      Instrumentation.telemetry_metadata(state, %{tool_name: call.name, call_id: call.id})
    )

    # The catalog, the hooks and the wording, bound here: see `provider_route/1`
    # for what naming `state` inside this closure used to cost.
    runner = %{id: state.id, tools: state.tools, hooks: state.hooks, messages: state.messages}

    task =
      Task.Supervisor.async(Sup.task_supervisor(state.supervisor), fn ->
        OpenTelemetry.with_context(runner.id, :tool, call.id, fn ->
          run_tool(runner, call, context, session, stream_ref, descriptor, budget)
        end)
      end)

    timer = Approvals.tool_timer(state, task.ref, timeout_ms, timeout_ms)

    # The task rides along with the call because cancelling has to reach the
    # process, and a bare ref cannot be killed.
    %{task.ref => {task, call, stream_ref, started, timer, descriptor}}
  end

  defp run_tool(runner, call, context, session, stream_ref, _descriptor, :ok) do
    Tools.run(runner.tools, runner.hooks, call, context, fn text ->
      send(session, {:tool_delta, stream_ref, call.id, call.name, text})
    end)
  end

  defp run_tool(runner, call, _context, _session, _stream_ref, descriptor, {:error, payload}) do
    tool_budget_result(runner, call, descriptor, payload)
  end

  defp tool_budget(%{max_cost_usd: nil}, _call, _reserved), do: {:ok, 0.0}

  defp tool_budget(state, call, reserved) do
    descriptor = call_descriptor(state, call)
    estimate = if descriptor, do: Descriptor.external_cost_max_usd(descriptor), else: 0.0
    spent = if is_number(state.spent_usd), do: state.spent_usd + reserved, else: nil

    if is_number(spent) and is_number(estimate) and spent + estimate <= state.max_cost_usd,
      do: {:ok, estimate},
      else: {:error, %{spent: spent, estimate: estimate, cap: state.max_cost_usd}}
  end

  defp tool_budget_result(runner, call, descriptor, payload) do
    output = Messages.render(runner.messages, :tool_budget_denied, [payload])

    %{
      call_id: call.id,
      name: call.name,
      arguments: Map.get(call, :arguments, %{}),
      output: output,
      error?: true,
      outcome: :budget,
      descriptor_digest: descriptor_digest(descriptor),
      tool_identity: descriptor_identity(descriptor),
      output_bytes: byte_size(output)
    }
  end

  def call_descriptor(state, call) do
    case Tool.fetch(state.tools, call.name) do
      {:ok, tool} -> Tool.descriptor(tool)
      :error -> nil
    end
  end

  def descriptor_timeout(nil, host_max), do: host_max
  def descriptor_timeout(descriptor, host_max), do: Descriptor.timeout_ms(descriptor, host_max)

  # `deadline_ms` is the clock this call actually got — the descriptor's deadline
  # under the host maximum — so a tool that waits on something it started can give
  # that something a shorter one. `delegate` does: a group told nothing about the
  # tool's clock ran on after the tool was stopped, writing results nobody read.
  defp tool_context(state, call, session, deadline_ms) do
    %{
      cwd: state.cwd,
      environment: state.environment,
      session_id: state.id,
      call_id: call.id,
      session: session,
      supervisor: state.supervisor,
      tool_output_bytes: state.tool_output_bytes,
      deadline_ms: deadline_ms,
      input_modalities: input_modalities(state)
    }
  end

  # What the current model can be shown besides text: the host's answer, or
  # the provider's, or `:unknown`. Asked per call rather than cached, because
  # `/model` changes the answer and a stale "yes" sends an image to a model
  # that refuses the request for it. The provider callback is optional — a
  # provider that cannot say leaves tools answering in words.
  defp input_modalities(%{input_modalities: modalities}) when is_list(modalities), do: modalities

  defp input_modalities(%{provider: provider, model: model}) when is_binary(model),
    do: Provider.input_modalities(provider, model)

  defp input_modalities(_state), do: :unknown

  # A tool result's attachments are kept only when the model can read them.
  # `read` already asked, but an MCP server attaches whatever it produced, and
  # an image in the transcript is sent on every later request: to a model that
  # cannot take it, that is every later request refused. What was dropped is
  # named in the output instead.
  defp admitted(%{attachments: [_ | _] = attachments} = result, state) do
    modalities = input_modalities(state)
    {kept, dropped} = Enum.split_with(attachments, &Attachment.accepted?(&1, modalities))

    result =
      if kept == [], do: Map.delete(result, :attachments), else: %{result | attachments: kept}

    case dropped do
      [] ->
        result

      _dropped ->
        output = result.output <> "\n" <> not_admitted(dropped, modalities)
        %{result | output: output, output_bytes: byte_size(output)}
    end
  end

  defp admitted(result, _state), do: result

  defp not_admitted(dropped, modalities) do
    count = length(dropped)
    noun = if count == 1, do: "attachment", else: "attachments"

    why =
      if modalities == :unknown,
        do: "this session does not know whether its model can read them",
        else: "the current model cannot read them"

    "[#{count} #{noun} from this result #{if count == 1, do: "is", else: "are"} not shown: #{why}]"
  end

  def tool_finished(state, ref, outcome) do
    {{_task, call, _stream_ref, started, timer, descriptor}, tasks} =
      Map.pop(state.wave.tool_tasks, ref)

    Approvals.cancel_timer(state, timer)
    state = Prompts.drop_parked_call(state, call.id)

    duration_ms = max(System.monotonic_time(:millisecond) - started, 0)
    {receipt, receipts} = Map.pop(state.wave.tool_receipts, call.id)

    result =
      state
      |> result(call, outcome, descriptor, receipt)
      |> Map.put(:duration_ms, duration_ms)
      |> admitted(state)

    Telemetry.stop_ms(
      [:tool, :call],
      duration_ms,
      Instrumentation.telemetry_metadata(state, %{
        tool_name: call.name,
        call_id: call.id,
        outcome: result.outcome
      })
    )

    state = %{
      state
      | wave: %{
          state.wave
          | tool_tasks: tasks,
            tool_results: Map.put(state.wave.tool_results, call.id, result),
            tool_receipts: receipts
        }
    }

    state = Accounting.account_tool_cost(state, result)

    state = Core.append(state, {:tool_result, payload(result), nil})

    # Every call in a wave is answered before the next request, because a provider
    # will not accept an assistant turn whose calls are partly answered. What is left
    # may be the next serial call rather than nothing, so this asks the scheduler
    # rather than deciding for it.
    if map_size(tasks) == 0, do: start_tools(state), else: state
  end

  defp result(_state, _call, result, _descriptor, receipt) when is_map(result),
    do: Receipt.reported(result, receipt)

  # A lost result. `Lemieux.Tool.Receipt` decides whether the model is told
  # the tool crashed or that its outcome is unknown, from what the tool
  # declared and what it recorded before it was lost.
  defp result(state, call, {:crashed, reason}, descriptor, receipt) do
    Receipt.lost(
      call,
      descriptor,
      receipt,
      :crashed,
      Messages.render(state.messages, :tool_crashed, [call, reason])
    )
  end

  defp result(state, call, {:timeout, timeout_ms}, descriptor, receipt) do
    Receipt.lost(
      call,
      descriptor,
      receipt,
      :timeout,
      Messages.render(state.messages, :tool_timed_out, [call, timeout_ms])
    )
  end

  defp descriptor_digest(nil), do: nil
  defp descriptor_digest(descriptor), do: descriptor.digest

  defp descriptor_identity(nil), do: nil
  defp descriptor_identity(descriptor), do: descriptor.identity

  def running_call(state, call_id) do
    Enum.find_value(state.wave.tool_tasks, fn
      {_ref, {_task, %{id: ^call_id} = call, _stream_ref, _started, _timer, _descriptor}} -> call
      _other -> nil
    end)
  end

  defp tools_done(state) do
    results = Enum.map(state.wave.tool_order, &Map.fetch!(state.wave.tool_results, &1))

    state =
      %{state | wave: %{state.wave | tool_results: %{}, tool_order: []}} |> note_wave(results)

    case guard(state) do
      :continue when state.turns_taken >= state.max_turns ->
        stop(
          state,
          :max_turns,
          Messages.render(state.messages, :turn_budget_spent, [state.max_turns])
        )

      :continue ->
        Compacting.continue(state)

      {:stop, reason, message} ->
        stop(state, reason, message)
    end
  end

  # The one place the loop asks whether to go on. `Lemieux.Session.Guard`
  # holds the rule; this holds the record it reads, and hands over the
  # messages module so a stop is worded the way the host asked.
  defp guard(state) do
    {module, gstate} = state.guard

    module.decide(gstate, %{
      recent_calls: state.wave.recent_calls,
      repeats: state.wave.repeats,
      last_wave: state.wave.last_wave,
      turns_taken: state.turns_taken,
      max_turns: state.max_turns,
      messages: state.messages
    })
  end

  def stop(state, reason, said) do
    state
    |> Instrumentation.finish_turn_telemetry(reason)
    |> Instrumentation.finish_prompt_telemetry(reason)
    |> Audit.ensure_harness_snapshot()
    |> Core.append({:error, %{"reason" => said}, nil})
    |> Audit.finalize_run(reason)
    |> then(&Core.emit(&1, {:context, Compacting.context(&1)}))
    |> Core.emit({:finished, reason})
  end

  # `max_turns` is a budget, not a guard: it catches a loop eventually, having paid
  # for every round on the way, and the most expensive loops look productive — a
  # denied command or an identically failing test, called again because nothing
  # tells the model it has been here before.
  #
  # So a wave is fingerprinted by what was asked *and* what came back. Asking twice
  # is not the problem — re-running the tests after an edit is exactly right, and a
  # detector keying on the call alone kills that. `Lemieux.Session.Guard` reads two
  # rules off the one record: the wave rule catches the same round three times, and
  # the window rule catches a model alternating between two or three rounds, which
  # `read a, read b, read a, read b` never trips the first of.
  #
  # A result that says the thing it reports on is still in progress is neither.
  # Polling a background command, or any tool reporting a job as `running`,
  # legitimately asks the same thing and hears the same answer while it waits,
  # and a guard that counted those stopped a session for waiting on its own
  # test suite. Such a result joins neither the round's fingerprint nor the
  # window; the turn budget still bounds a model that polls forever.
  defp note_wave(state, results) do
    settled = Enum.reject(results, &in_progress?/1)
    recent = Enum.take(state.wave.recent_calls ++ settled, -@recent_calls)

    wave =
      cond do
        settled == [] ->
          %{state.wave | last_wave: nil, repeats: 0, recent_calls: recent}

        fingerprint(settled) == state.wave.last_wave ->
          %{state.wave | repeats: state.wave.repeats + 1, recent_calls: recent}

        true ->
          %{state.wave | last_wave: fingerprint(settled), repeats: 1, recent_calls: recent}
      end

    %{state | wave: wave}
  end

  defp in_progress?(%{structured_content: %{"status" => status}}) when status in @in_progress,
    do: true

  defp in_progress?(%{metadata: %{"in_progress" => true}}), do: true
  defp in_progress?(_result), do: false

  # Sorted, because a model that asks for the same two tools in the other
  # order has not thereby made progress. Hashed, because the outputs are
  # whole files and whole build logs, and this is kept between turns.
  defp fingerprint(results) do
    results
    |> Enum.map(&{&1.name, &1.arguments, &1.output, &1.error?})
    |> Enum.sort()
    |> :erlang.phash2()
  end

  def payload(result) do
    base = %{
      "call_id" => result.call_id,
      "name" => result.name,
      "arguments" => result.arguments,
      "output" => result.output,
      "error" => result.error?,
      "duration_ms" => result.duration_ms,
      "outcome" => result |> Map.get(:outcome, :error) |> Atom.to_string(),
      "output_bytes" => Map.get(result, :output_bytes, byte_size(result.output))
    }

    [
      {:descriptor_digest, "descriptor_digest"},
      {:tool_identity, "tool_identity"},
      {:structured_content, "structured_content"},
      {:content, "content"},
      {:artifacts, "artifacts"},
      {:attachments, "attachments"},
      {:cost, "cost"},
      {:metadata, "metadata"},
      {:receipt, "receipt"},
      {:hook_rewritten?, "hook_rewritten"}
    ]
    |> Enum.reduce(base, fn {atom_key, string_key}, payload ->
      case Map.fetch(result, atom_key) do
        {:ok, value} -> Map.put(payload, string_key, value)
        :error -> payload
      end
    end)
  end

  def checkpoint_turn(%{turn: %Turn{} = turn} = state) do
    case Turn.checkpoint(turn) do
      nil -> state
      entry_spec -> apply_effect(state, {:append, entry_spec})
    end
  end

  def checkpoint_turn(state), do: state

  def checkpoint_cancelled_tools(%{wave: %{tool_order: []}} = state), do: state

  def checkpoint_cancelled_tools(state) do
    calls =
      state.wave.tool_tasks
      |> Map.values()
      |> Enum.map(fn {_task, call, _stream_ref, _started, _timer, _descriptor} -> call end)
      |> Kernel.++(List.flatten(state.wave.tool_batches))
      |> Map.new(&{&1.id, &1})

    state.wave.tool_order
    |> Enum.reject(&Map.has_key?(state.wave.tool_results, &1))
    |> Enum.reduce(state, fn call_id, state ->
      case Map.fetch(calls, call_id) do
        {:ok, call} ->
          cancelled =
            Receipt.lost(
              call,
              call_descriptor(state, call),
              Map.get(state.wave.tool_receipts, call.id),
              :cancelled,
              Messages.render(state.messages, :tool_cancelled, [call])
            )

          Core.append(state, {:tool_result, payload(cancelled), nil})

        :error ->
          state
      end
    end)
  end
end
