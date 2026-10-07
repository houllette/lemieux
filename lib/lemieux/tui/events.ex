# The session's own events: what each changes about the turn in flight (its
# phase, usage and signals) and what each draws (tool calls and their output,
# approval cards, questions, compaction, delegated children).
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Events do
    @moduledoc "Applies a session's `{:lemieux, id, event}` messages to a `Lemieux.TUI`."

    alias Lemieux.Conversation
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Followup
    alias Lemieux.TUI.MCPStatus
    alias Lemieux.TUI.Notify
    alias Lemieux.TUI.Pager
    alias Lemieux.TUI.PlanPanel
    alias Lemieux.TUI.Policy
    alias Lemieux.TUI.QuestionFlow
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.SubagentPresentation
    alias Lemieux.TUI.Submission
    alias Lemieux.TUI.ToolText
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.TranscriptPresentation
    alias Lemieux.TUI.Turn
    alias Lemieux.TUI.WriteDiff

    @typep reply :: {:noreply, TUI.t()} | {:stop, TUI.t()}

    # One event, in the order the screen owes it: the conversation's reading
    # first, then what the event says about the turn, then what it draws, and
    # only then the effects the conversation asked for.
    @doc false
    @spec handle(TUI.t(), term()) :: reply()
    def handle(state, event) do
      {conversation, effects} = Conversation.event(state.conversation, event)
      state = sync_event(%{state | conversation: conversation}, event)
      {state, effects} = present_event(state, event, effects)
      state = resolved_question_flow(state, event)

      state
      |> Effects.run(effects)
      |> finish_event(event)
    end

    @doc false
    @spec phase(TUI.t(), atom(), term()) :: TUI.t()
    def phase(state, kind, detail \\ nil) do
      case state.turn.phase do
        # The same phase continuing keeps its clock; a changed detail (more
        # bytes composed, a different tool) is still the same wait.
        %{kind: ^kind, since: since} ->
          put_in(state.turn.phase, %{kind: kind, detail: detail, since: since})

        _other ->
          put_in(state.turn.phase, %{kind: kind, detail: detail, since: state.clock.()})
      end
    end

    defp sync_event(state, {:model_changed, _old, model}),
      do: state |> Choices.remember_model(model) |> Choices.refresh_choices()

    defp sync_event(state, {:reasoning_effort_changed, _old, _effort}),
      do: Choices.refresh_choices(state)

    defp sync_event(state, {:tools_changed, _old, names}), do: Choices.elixir_mode(state, names)

    defp sync_event(state, {:tool_access_changed, _action, _names, local_names}) do
      state
      |> Choices.elixir_mode(local_names)
      |> Choices.put_tool_statuses(Session.tool_status(state.session))
    end

    defp sync_event(%TUI{turn: %{started_at: started}} = state, {:usage, usage})
         when is_integer(started) and is_map(usage),
         do: put_in(state.turn.usage, Turn.add_usage(state.turn.usage, usage))

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:subagent, [_root_id, _child_id], {:usage, usage}}
         )
         when is_integer(started) and is_map(usage),
         do: put_in(state.turn.usage, Turn.add_usage(state.turn.usage, usage))

    defp sync_event(%TUI{turn: %{started_at: started}} = state, {:tool_call, call})
         when is_integer(started) do
      name = field(call, :name, "name", "tool")

      state
      |> update_in([Access.key!(:turn), :usage, :tool_calls], &(&1 + 1))
      |> update_in([Access.key!(:turn), :signals], &Followup.called(&1, name))
      |> phase(:tool, %{name: name})
    end

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:subagent, [_root_id, _child_id], {:tool_call, _call}}
         )
         when is_integer(started),
         do: update_in(state, [Access.key!(:turn), :usage, :tool_calls], &(&1 + 1))

    # A delegated child's failures are the child's business, but the parent's
    # own are what the person is looking at when the turn ends.
    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:entry, %{type: :tool_result, payload: payload}}
         )
         when is_integer(started),
         do:
           update_in(
             state,
             [Access.key!(:turn), :signals],
             &Followup.returned(&1, payload["error"] == true)
           )

    # The phases. Each event that says what the session is doing now updates
    # the live row's clause; events that say nothing about that leave it.
    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:entry, %{type: :request}}
         )
         when is_integer(started),
         do: state |> counted() |> Submission.mark_steers(:sent) |> phase(:waiting)

    defp sync_event(state, {:entry, %{type: :request}}),
      do: state |> counted() |> Submission.mark_steers(:sent)

    # The prompt is waiting a bounded moment for MCP servers still
    # connecting; the live row says which, so the pause is not a mystery.
    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:waiting_for_mcp, %{servers: servers}}
         )
         when is_integer(started),
         do: phase(state, :connecting, %{servers: servers})

    defp sync_event(%TUI{turn: %{started_at: started}} = state, {:thinking_delta, _delta})
         when is_integer(started),
         do: state |> phase(:thinking) |> put_in([Access.key!(:turn), :delegation], nil)

    defp sync_event(%TUI{turn: %{started_at: started}} = state, {:text_delta, _delta})
         when is_integer(started),
         do: state |> phase(:answering) |> put_in([Access.key!(:turn), :delegation], nil)

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:tool_call_delta, %{name: name, bytes: bytes, head: head}}
         )
         when is_integer(started) do
      state
      |> phase(:composing, %{name: name || "a tool call", target: call_target(head), bytes: bytes})
      |> put_in([Access.key!(:turn), :delegation], nil)
    end

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:tool_delta, %{name: name}}
         )
         when is_integer(started),
         do: phase(state, :tool, %{name: name})

    # A parked call is a wait on the person, and the live row says so until
    # the decision lands — whichever of the session's two announcements
    # arrives first — and says `running` again once it has.
    defp sync_event(%TUI{turn: %{started_at: started}} = state, {:tool_approval, call})
         when is_integer(started) and is_map(call),
         do: phase(state, :approval, %{name: field(call, :name, "name", "a tool")})

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:entry, %{type: :approval, payload: %{"kind" => "approval"} = payload}}
         )
         when is_integer(started) do
      case payload do
        %{"status" => "pending", "detail" => %{"name" => name}} ->
          phase(state, :approval, %{name: name})

        %{"status" => "pending"} ->
          phase(state, :approval, %{name: "a tool"})

        %{"call_id" => id} ->
          phase(state, :tool, %{name: announced_name(state, id)})
      end
    end

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:provider_retry,
            %{attempt: attempt, max: max, delay_ms: delay, category: category} = retry}
         )
         when is_integer(started) do
      phase(state, :retrying, %{
        attempt: attempt,
        max: max,
        delay_ms: delay,
        kind: Conversation.retry_kind(category),
        after_output: Map.get(retry, :after_output, false)
      })
    end

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:subagent, [_root_id], {:child_started, _payload}}
         )
         when is_integer(started),
         do: phase(state, :delegating, %{running: running_children(state) + 1})

    defp sync_event(
           %TUI{turn: %{started_at: started, phase: %{kind: :delegating}}} = state,
           {:subagent, [_root_id], {:child_finished, _payload}}
         )
         when is_integer(started),
         do: phase(state, :delegating, %{running: max(running_children(state) - 1, 0)})

    defp sync_event(
           %TUI{turn: %{started_at: started}} = state,
           {:subagent, [_root_id], {:group_finished, payload}}
         )
         when is_integer(started) do
      results = List.wrap(payload["results"])
      bytes = results |> Enum.map(&byte_size(&1["answer"] || "")) |> Enum.sum()

      state
      |> put_in([Access.key!(:turn), :delegation], %{count: length(results), bytes: bytes})
      |> put_in([Access.key!(:turn), :phase], nil)
    end

    defp sync_event(state, _event), do: state

    defp running_children(%TUI{turn: %{phase: %{kind: :delegating, detail: %{running: n}}}}),
      do: n

    defp running_children(_state), do: 0

    defp announced_name(state, id) do
      case Map.get(state.tools.calls, id) do
        nil -> "a tool"
        call -> field(call, :name, "name", "a tool")
      end
    end

    # The path or command inside a call's first bytes of arguments, which is
    # what a person wants to know about a write they are waiting on.
    defp call_target(head) when is_binary(head) do
      case Regex.run(~r/"(?:path|command|file_path)"\s*:\s*"((?:[^"\\]|\\.)*)/, head) do
        [_whole, target] -> target |> String.replace("\\\"", "\"") |> String.slice(0, 80)
        _none -> nil
      end
    end

    defp call_target(_head), do: nil

    defp finish_event({:noreply, state}, {:finished, reason}) do
      # An aside can finish normally with a steer still queued for the next
      # prompt. Cancellation and other stops discard it at the session layer.
      state = if reason in [:stop, :ok], do: state, else: Submission.mark_steers(state, :not_sent)
      elapsed = Screen.elapsed(state)

      state =
        state
        |> Submission.flush_deferred_steer()
        |> Turn.finish_processing()
        |> Notify.finished(elapsed)

      if reason in [:stop, :ok], do: Submission.continue_queued(state), else: {:noreply, state}
    end

    defp finish_event(result, _event), do: result

    # A call is announced once. The event can arrive twice — a host that
    # attaches mid-turn is sent the pending call and then the live one — and
    # for `ask_user` a second announcement is a second copy of the question,
    # which is what the duplicate-question bug looked like from the outside.
    defp present_event(%{turn: %{compacting: %{}}} = state, {:compacted, _data}, effects) do
      report =
        Enum.find_value(effects, fn
          {:say, text} -> text
          _other -> nil
        end)

      state =
        state
        |> replace_compact_row(
          {:compact_result,
           "Compacted " <> String.trim_leading(report) <> systemone_report(state.tools.systemone)}
        )
        |> put_in([Access.key!(:turn), :compacting], nil)

      {state, without(effects, :say)}
    end

    defp present_event(
           %{tools: %{systemone: %{} = systemone}} = state,
           {:entry,
            %{
              type: :extension_state,
              payload: %{"namespace" => "systemone_compaction", "value" => value}
            }},
           effects
         )
         when is_map(value) do
      updated = %{
        systemone
        | saved: Map.get(value, "last_saved_tokens_estimate"),
          outcome: Map.get(value, "last_outcome")
      }

      {put_in(state.tools.systemone, updated), effects}
    end

    defp present_event(state, {:tool_call, call}, effects) do
      id = Map.get(call, :id) || Map.get(call, "id") || "tool"

      state =
        state
        |> announce(id, call)
        |> put_in([Access.key!(:tools), :calls, id], call)

      {state, without(effects, :say)}
    end

    defp present_event(state, {:tool_delta, delta}, effects) when is_map(delta) do
      id = Map.get(delta, :call_id) || Map.get(delta, "call_id") || "tool"
      text = Map.get(delta, :text) || Map.get(delta, "text") || ""
      output = Map.get(state.tools.outputs, id, "") <> text

      state =
        state
        |> put_in([Access.key!(:tools), :outputs, id], output)
        |> replace_output(id, output)

      {state, without(effects, :write)}
    end

    defp present_event(state, {:entry, %{type: :tool_result, payload: payload}}, effects) do
      id = payload["call_id"] || "tool"

      call =
        Map.get(state.tools.calls, id, %{
          id: id,
          name: payload["name"],
          arguments: payload["arguments"] || %{}
        })

      state =
        state
        |> announce(id, call)
        |> present_result(id, call, payload)
        |> Pager.remember(id, field(call, :name, "name", "tool"), output_text(payload["output"]))
        |> WriteDiff.request(id, call, payload)

      state =
        if map_size(state.tools.calls) == 0,
          do: Submission.flush_deferred_steer(state),
          else: state

      state = clear_question_flow(state, id)
      {state, without(effects, :say)}
    end

    defp present_event(state, {:question, %{ask_user: true} = question}, effects) do
      state =
        if state.tools.question_flow,
          do: state,
          else: state |> open_question_flow(question) |> Notify.waiting("your answer")

      {state, without(effects, :say)}
    end

    defp present_event(state, {:question, question}, effects) do
      id = Map.get(question, :call_id) || Map.get(question, "call_id") || "question"

      state =
        if ToolText.announced?(state.lines, id),
          do: state,
          else: Transcript.append_rows(state, ToolText.question_rows(question))

      {state, without(effects, :say)}
    end

    # A parked call's card: rows of its own under the announcement, kept
    # apart from it so the decision can take exactly them down again. Either
    # of the session's two announcements draws it, whichever arrives first,
    # and the conversation's own line for it is dropped the way a tool
    # call's is.
    defp present_event(state, {:tool_approval, call}, effects) when is_map(call) do
      state =
        state
        |> present_approval(approval_call(call))
        |> Notify.waiting("your approval of #{field(call, :name, "name", "a tool")}")

      {state, without(effects, :say)}
    end

    defp present_event(
           state,
           {:entry,
            %{type: :approval, payload: %{"kind" => "approval", "status" => "pending"} = p}},
           effects
         ),
         do: {present_approval(state, approval_call(p)), without(effects, :say)}

    defp present_event(
           state,
           {:entry, %{type: :approval, payload: %{"kind" => "approval", "call_id" => id}}},
           effects
         ),
         do: {resolve_approval(state, id), effects}

    defp present_event(state, {:subagent, path, event}, effects) do
      {SubagentPresentation.present(state, path, event), effects}
    end

    defp present_event(state, {:mcp_server, status}, effects),
      do: {MCPStatus.update(state, status), effects}

    # Ready is also when the `@` picker's resources can first be listed: the
    # servers connected in the background. See `Lemieux.TUI.ResourceIndex`.
    defp present_event(state, {:ready, %{mcp: statuses}}, effects),
      do: {state |> MCPStatus.ready(statuses) |> Composer.refresh_resources(), effects}

    defp present_event(state, {:mcp_list_changed, %{kind: :resources}}, effects),
      do: {Composer.refresh_resources(state), effects}

    # A list-changed notification adds or removes tools; the catalog the menus
    # offer is asked for again, in a task.
    defp present_event(state, {:mcp_list_changed, _change}, effects),
      do: {MCPStatus.refresh(state), effects}

    # What the session says about its window is the conversation's sentence,
    # drawn as a notice rather than as a line of narration, and only once.
    # The sentence is the conversation's because it is the one that knows a
    # local Ollama model's window is the daemon's to change — this screen's
    # own told such a person to set `context_window`, which cannot — and what
    # a host that turned the fallback off gets instead of a number.
    defp present_event(state, {:context_window_unknown, %{model: model}}, effects),
      do: conversation_notice(state, {:context_window_unknown, model}, effects)

    defp present_event(
           state,
           {:context_window_small, %{model: model, window: window}},
           effects
         ),
         do: conversation_notice(state, {:context_window_small, model, window}, effects)

    defp present_event(state, {:run_evidence_failed, %{reason: reason}}, effects),
      do:
        {once(
           state,
           :run_evidence_failed,
           "this turn's run record could not be written: #{inspect(reason)}"
         ), effects}

    defp present_event(state, {:entry, %{type: :extension_state} = entry}, effects),
      do: {PlanPanel.observe(state, entry), effects}

    # A stop hook's message to the model — verify's report, continuation's
    # nudge, a command hook's feedback — arrives as a user message the person
    # did not type, so nothing else draws it. What the person typed was drawn
    # when it was submitted.
    defp present_event(state, {:entry, %{type: :user} = entry}, effects) do
      case TranscriptPresentation.harness_lines(entry) do
        [] -> {state, effects}
        rows -> {Transcript.append_rows(state, rows), effects}
      end
    end

    # An attempt the stream broke off in the middle of: kept on the record,
    # never sent back to the model, and marked here so it does not read as
    # the answer.
    defp present_event(
           state,
           {:entry, %{type: :assistant, payload: %{"partial" => true}}},
           effects
         ),
         do:
           {Transcript.append_rows(state, [
              {:interrupted, "interrupted · this partial answer was kept, and is not sent back"}
            ]), effects}

    defp present_event(state, _event, effects), do: {state, effects}

    # The conversation's line as a notice row: its leading dot dropped, and
    # what to do about it — after the first ` · ` — on the row's second line,
    # where a notice keeps its remedy.
    defp conversation_notice(state, key, effects) do
      said =
        Enum.find_value(effects, fn
          {:say, text} -> text
          _other -> nil
        end)

      case said do
        nil ->
          {state, effects}

        text ->
          notice =
            text
            |> String.trim_leading()
            |> String.trim_leading("· ")
            |> String.replace(" · ", "; ", global: false)

          {once(state, key, notice), without(effects, :say)}
      end
    end

    # A notice the session may repeat — a resume replays what it said — is
    # drawn once per sitting.
    defp once(state, key, text) do
      if key in state.session_view.noticed do
        state
      else
        state
        |> update_in([Access.key!(:session_view), :noticed], &[key | &1])
        |> Transcript.say(:notice, text)
      end
    end

    defp counted(state), do: update_in(state, [Access.key!(:session_view), :requests], &(&1 + 1))

    @doc false
    @spec present_approval(TUI.t(), map()) :: TUI.t()
    def present_approval(state, %{id: id} = call) do
      if Map.has_key?(state.tools.approvals, id) do
        state
      else
        permission = Map.get(call, :permission)

        rows =
          ToolText.approval(call, Screen.renderers(state)) ++ Policy.card_rows(id, permission)

        state
        |> Transcript.append_rows(rows)
        |> put_in([Access.key!(:tools), :approvals, id], rows)
        |> update_in(
          [Access.key!(:tools)],
          &Map.update(&1, :permissions, %{id => permission}, fn known ->
            Map.put(known, id, permission)
          end)
        )
      end
    end

    # The card's own rows come down — first match from the newest end, so a
    # row identical to one in the announcement above still leaves that one —
    # and the call's announcement stays for the result to land under.
    defp resolve_approval(state, id) do
      case Map.pop(state.tools.approvals, id) do
        {nil, _approvals} ->
          state

        {rows, approvals} ->
          lines = Enum.reduce(rows, state.lines, &List.delete(&2, &1))

          tools =
            state.tools
            |> Map.put(:approvals, approvals)
            |> Map.update(:permissions, %{}, &Map.delete(&1, id))

          %{keeping(state, lines) | tools: tools}
      end
    end

    # The parked call as the event carries it (the hook's own `%{id:, name:,
    # arguments:}`) or as the entry recorded it, as one renderer-shaped call.
    defp approval_call(%{"call_id" => id, "detail" => detail}) when is_map(detail),
      do: %{
        id: id,
        name: detail["name"] || "tool",
        arguments: detail["arguments"] || %{},
        permission: detail["permission"]
      }

    defp approval_call(call) do
      %{
        id: field(call, :id, "id", nil) || field(call, :call_id, "call_id", "tool"),
        name: field(call, :name, "name", "tool"),
        arguments: field(call, :arguments, "arguments", %{}),
        permission: field(call, :permission, "permission", nil)
      }
    end

    defp field(map, atom_key, string_key, default) do
      case Map.fetch(map, atom_key) do
        {:ok, value} -> value
        :error -> Map.get(map, string_key, default)
      end
    end

    defp present_result(state, id, call, payload) do
      state =
        case ToolText.result(call, payload, Screen.theme(state), Screen.renderers(state)) do
          :none ->
            state

          {:output, output} ->
            replace_output(state, id, output, TranscriptPresentation.tone(payload))

          {:answer, answer} ->
            replace_answer(state, id, answer)

          {:replace, rows} ->
            state |> remove_call_rows(id) |> Transcript.append_rows(rows)
        end

      %{state | tools: forget(state.tools, id)}
    end

    defp output_text(text) when is_binary(text), do: text
    defp output_text(nil), do: ""
    defp output_text(other), do: inspect(other, limit: 50, printable_limit: 20_000)

    defp without(effects, kind),
      do: Enum.reject(effects, &match?({^kind, _payload}, &1))

    defp announce(state, id, call) do
      if ToolText.announced?(state.lines, id),
        do: state,
        else:
          Transcript.append_rows(
            state,
            ToolText.call(
              call,
              ToolText.exploration_head?(state.lines),
              Screen.renderers(state),
              Screen.theme(state)
            )
          )
    end

    defp remove_call_rows(state, id),
      do: keeping(state, Enum.reject(state.lines, &(ToolText.call_id(&1) == id)))

    defp replace_output(state, id, output, tone \\ :ok) do
      kept = Enum.reject(state.lines, &ToolText.output?(&1, id))

      Transcript.append_rows(
        keeping(state, kept),
        ToolText.output_rows(id, output, Screen.columns(state), tone)
      )
    end

    defp replace_answer(state, id, answer) do
      kept = Enum.reject(state.lines, &ToolText.answer?(&1, id))
      Transcript.append_rows(keeping(state, kept), ToolText.answer_rows(id, answer))
    end

    # A placeholder replaced by its result is the one edit a depth cannot follow:
    # rows vanishing from the middle move everything above them by an amount `held/2`
    # cannot know. Dropping the highlight is honest; shifting it by the append alone
    # would leave it over text nobody dragged.
    defp keeping(state, kept),
      do: %{state | lines: kept, selection: nil, terminal: %{state.terminal | row_cache: nil}}

    defp forget(%{calls: calls, outputs: outputs} = tools, id),
      do: %{tools | calls: Map.delete(calls, id), outputs: Map.delete(outputs, id)}

    # The compaction row: drawn when `/compact` is sent, ticking once a second
    # while the summary is written, and replaced by the report when the
    # session's `:compacted` event arrives.
    @doc false
    @spec start_compact_display(TUI.t()) :: TUI.t()
    def start_compact_display(state) do
      tick = make_ref()
      Process.send_after(self(), {:compact_tick, tick}, 1_000)

      state
      |> Transcript.append_rows([
        {:compact_space, tick},
        {:compacting, tick, "Compacting...(0s)"},
        {:compact_space, tick}
      ])
      |> put_in([Access.key!(:turn), :compacting], %{since: state.clock.(), tick: tick})
    end

    @doc false
    @spec compact_tick(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def compact_tick(%TUI{turn: %{compacting: %{tick: tick} = compacting}} = state, tick) do
      Process.send_after(self(), {:compact_tick, tick}, 1_000)
      seconds = max(div(state.clock.() - compacting.since, 1_000), 0)
      {:noreply, replace_compact_row(state, {:compacting, tick, "Compacting...(#{seconds}s)"})}
    end

    def compact_tick(state, _tick), do: {:noreply, state}

    @doc false
    @spec remove_compact_row(TUI.t()) :: TUI.t()
    def remove_compact_row(%{turn: %{compacting: nil}} = state), do: state

    def remove_compact_row(state) do
      tick = state.turn.compacting.tick

      kept =
        Enum.reject(state.lines, fn
          {:compacting, ^tick, _text} -> true
          {:compact_space, ^tick} -> true
          _other -> false
        end)

      state |> keeping(kept) |> put_in([Access.key!(:turn), :compacting], nil)
    end

    defp replace_compact_row(state, row) do
      tick = state.turn.compacting.tick

      lines =
        Enum.map(state.lines, fn
          {:compacting, ^tick, _text} -> row
          other -> other
        end)

      %{state | lines: lines}
    end

    defp systemone_report(nil), do: ""
    defp systemone_report(%{mode: "shadow"}), do: " · System One shadow, no context removed"

    defp systemone_report(%{saved: saved}) when is_integer(saved) and saved > 0,
      do: " · last System One projection kept ≈#{Turn.compact_number(saved)} tok out of context"

    defp systemone_report(%{outcome: nil}),
      do: " · System One compaction active, no projection recorded yet"

    defp systemone_report(_systemone),
      do: " · System One compaction active, no context saved in the last projection"

    # An `ask_user` question takes the input box over; what was being typed is
    # kept in the flow and put back when the question is answered or dropped.
    @doc false
    @spec open_question_flow(TUI.t(), map()) :: TUI.t()
    def open_question_flow(state, question) do
      flow = QuestionFlow.new(question, Composer.typed_value(state))
      :ok = ExRatatui.textarea_set_value(state.input, "")
      put_in(state.tools.question_flow, flow)
    end

    defp clear_question_flow(%{tools: %{question_flow: %{call_id: id} = flow}} = state, id) do
      :ok = Editor.replace(state.input, flow.draft)
      put_in(state.tools.question_flow, nil)
    end

    defp clear_question_flow(state, _id), do: state

    defp resolved_question_flow(
           state,
           {:entry,
            %{
              type: :approval,
              payload: %{"kind" => "question", "call_id" => id, "status" => status}
            }}
         )
         when status in ~w(answered timed_out),
         do: clear_question_flow(state, id)

    defp resolved_question_flow(state, {:finished, _reason}) do
      case state.tools.question_flow do
        %{call_id: id} -> clear_question_flow(state, id)
        nil -> state
      end
    end

    defp resolved_question_flow(state, _event), do: state
  end
end
