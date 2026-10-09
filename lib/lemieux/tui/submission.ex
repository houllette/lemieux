# What happens to a line once Enter sends it: a skill expanded, the line echoed
# as whatever it turned out to be, a steer held until it is sent, and the
# staged queue sent behind it when the turn ends.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Submission do
    @moduledoc "Sends what was typed into a `Lemieux.TUI` to its conversation and session."

    alias Lemieux.Conversation
    alias Lemieux.Conversation.Command.Unsteer
    alias Lemieux.Extensions.Workspace.Skill
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Events
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Lifecycle
    alias Lemieux.TUI.MCPStatus
    alias Lemieux.TUI.Policy
    alias Lemieux.TUI.ToolText
    alias Lemieux.TUI.Transcript

    @typep reply :: {:noreply, TUI.t()} | {:stop, TUI.t()}

    @doc false
    @spec submit(TUI.t()) :: reply()
    def submit(state), do: state.input |> ExRatatui.textarea_get_value() |> sending(state)

    # The session exited under the screen. Enter on an empty line brings it
    # back from its transcript; `/new`, `/resume` and `/quit` still work;
    # anything else would be a call to a process that is gone, so it stays in
    # the box until the session is back.
    defp sending("", %TUI{resume: %{down: down}} = state) when not is_nil(down),
      do: {:noreply, Lifecycle.resume_session(state, state.id)}

    defp sending(typed, %TUI{resume: %{down: down}} = state) when not is_nil(down) do
      if String.trim(typed) in ["/quit", "/exit", "/new", "/help"] or
           String.starts_with?(String.trim(typed), "/resume"),
         do: send_input(typed, state),
         else:
           {:noreply,
            Flash.show(state, "the session stopped · Enter on an empty line resumes it")}
    end

    defp sending("", state), do: {:noreply, state}

    # `a`, `a2`, `always` on a waiting approval card take one of the
    # permission extension's suggestions. See `Lemieux.TUI.Policy`.
    defp sending(typed, %TUI{conversation: %{approvals: [_ | _]}} = state) do
      case Policy.always(typed) do
        {:ok, index} ->
          :ok = ExRatatui.textarea_set_value(state.input, "")
          {:noreply, Policy.take(state, index)}

        :error ->
          sending_ordinary(typed, state)
      end
    end

    defp sending(typed, state), do: sending_ordinary(typed, state)

    defp sending_ordinary(typed, %{conversation: %{busy?: true}} = state) do
      if pending_steer_text(state) && not String.starts_with?(String.trim_leading(typed), "/"),
        do:
          {:noreply, Flash.show(state, "one steer is already waiting · /unsteer takes it back")},
        else: send_input(typed, state)
    end

    defp sending_ordinary(typed, state), do: send_input(typed, state)

    defp send_input("/mcp", state) do
      :ok = Editor.replace(state.input, "")

      case Conversation.command_decision(Choices.command_policy(state), :mcp_status) do
        :allow ->
          statuses = mcp_statuses(state)

          flow = %{
            statuses: statuses,
            selected: 0,
            mode: :list,
            step: :name,
            form: %{},
            notice: nil,
            busy?: false,
            confirm_remove: nil
          }

          {:noreply,
           state
           |> Choices.put_mcp_names(statuses)
           |> put_in([Access.key!(:tools), :mcp_flow], flow)}

        {:deny, reason} ->
          {:noreply, Flash.show(state, reason)}
      end
    end

    defp send_input("/mcp " <> _arguments, state), do: send_input("/mcp", state)

    defp send_input(typed, state) do
      # Cleared through the widget rather than by replacing the handle: the
      # editor's state is one buffer behind a reference, so a fresh reference
      # would leave the old one being drawn until the next frame rebuilt it.
      :ok = ExRatatui.textarea_set_value(state.input, "")

      # Echoed, because nothing else will: a terminal echoes what you type and
      # a widget does not, so without this the transcript is one side of the
      # conversation.
      {conversation, effects} = conversation_input(state, typed)
      effects = command_effects(typed, effects)

      %{
        state
        | conversation: conversation,
          selection: nil,
          command_menu?: true,
          command_index: 0,
          model_tab: "Automatic",
          command_tab: "Commands",
          history: state.history |> History.record(typed) |> History.browsing(nil)
      }
      |> echo_input(typed, effects)
      |> Effects.run(suppress_steer_ack(effects))
    end

    # While startup connections run, asking the session waits for the
    # slowest server; what the screen was told stands in, and the manager
    # lists the servers as connecting. Once they have settled the session
    # answers at once.
    defp mcp_statuses(%TUI{session_view: %{mcp_ready?: false}} = state),
      do: MCPStatus.statuses(state)

    defp mcp_statuses(state), do: Session.mcp_status(state.session)

    defp suppress_steer_ack(effects) do
      if Enum.any?(effects, &match?({:steer, _text}, &1)),
        do: Enum.reject(effects, &(&1 == {:say, "… noted, will pass it on"})),
        else: effects
    end

    defp conversation_input(%TUI{conversation: %{busy?: true}} = state, typed) do
      case invoked_skill(state, typed) do
        {:ok, _skill, _arguments} ->
          {state.conversation, [{:say, "wait for the current turn before invoking a skill"}]}

        :error ->
          Conversation.input(state.conversation, typed)
      end
    end

    defp conversation_input(state, typed) do
      case invoked_skill(state, typed) do
        {:ok, skill, arguments} ->
          case Skill.render(skill, arguments) do
            {:ok, rendered} -> Conversation.input(state.conversation, rendered)
            {:error, reason} -> {state.conversation, [{:say, "could not load skill: #{reason}"}]}
          end

        :error ->
          Conversation.input(state.conversation, typed)
      end
    end

    defp invoked_skill(state, "/" <> command) do
      case String.split(command, ~r/\s+/, parts: 2, trim: true) do
        [name | arguments] ->
          find_invoked_skill(state, name, List.first(arguments) || "")

        [] ->
          :error
      end
    end

    defp invoked_skill(_state, _typed), do: :error

    defp find_invoked_skill(state, name, arguments) do
      reserved =
        state.conversation
        |> Conversation.commands(Choices.command_policy(state))
        |> Enum.flat_map(&[&1.name | &1.aliases])

      if name in reserved do
        :error
      else
        case Enum.find(state.skills, &(Skill.qualified_name(&1) == name)) do
          nil -> :error
          skill -> {:ok, skill, arguments}
        end
      end
    end

    defp echo_input(state, typed, effects) do
      cond do
        :diff in effects and
            Conversation.command_decision(Choices.command_policy(state), :diff) == :allow ->
          state

        :compact in effects and
            Conversation.command_decision(Choices.command_policy(state), :compact) == :allow ->
          Events.start_compact_display(state)

        answer = Enum.find(effects, &match?({:answer, _call_id, _answer}, &1)) ->
          {:answer, call_id, value} = answer
          Transcript.append_rows(state, ToolText.answer_rows(call_id, value))

        steer = Enum.find(effects, &match?({:steer, _text}, &1)) ->
          {:steer, sent} = steer
          state = sent_steer(state, typed, sent)

          if map_size(state.tools.calls) > 0 do
            put_in(state.tools.deferred_steer, {:pending, typed})
          else
            Transcript.append_rows(state, [{:space, ""}, {:steer, :pending, typed}, {:space, ""}])
          end

        true ->
          Transcript.say(state, :you, typed)
      end
    end

    # Conversation stays the shared pure parser available to hosts. These
    # two commands normally become already-rendered `:say` effects; the
    # TUI keeps their parsed action until dispatch so its host policy can both
    # filter their contents and deny a command typed by hand.
    defp command_effects(typed, effects) do
      case String.trim(typed) do
        "/help" -> replace_said(effects, :help)
        "/context" -> replace_said(effects, :context_status)
        _other -> effects
      end
    end

    defp replace_said(effects, action),
      do:
        Enum.map(effects, fn
          {:say, _text} -> action
          effect -> effect
        end)

    @doc false
    @spec mark_steers(TUI.t(), :sent | :not_sent) :: TUI.t()
    def mark_steers(state, status) do
      lines =
        Enum.map(state.lines, fn
          {:steer, :pending, text} -> {:steer, status, text}
          row -> row
        end)

      state = %{state | lines: lines, tools: %{state.tools | sent_steers: []}}

      case state.tools.deferred_steer do
        {:pending, text} -> put_in(state.tools.deferred_steer, {status, text})
        _other -> state
      end
    end

    # What the session was handed for a steer is not what its row shows:
    # `Lemieux.Conversation.input/2` trims the line and puts any note a
    # `!command` or `/memory` left ahead of it, and `Lemieux.Session` takes a
    # steer back only by its exact text. Revoking with the row's text — a
    # line pasted with its newline, or one that carried a note — never
    # matched, so `/unsteer` said "already sent" and the steer went out with
    # the next request anyway. So the sent text is kept beside the row's,
    # newest first, for as long as the row is drawn as waiting.
    defp sent_steer(state, shown, sent),
      do: put_in(state.tools.sent_steers, [{shown, sent} | state.tools.sent_steers])

    defp pending_steer_text(state) do
      case pending_steer(state) do
        nil -> nil
        {_where, shown, _sent} -> shown
      end
    end

    # The waiting steer `/unsteer` would take back: where it is drawn (the
    # deferred slot under running tool calls, or a row), the text shown, and
    # the text the session holds. A row put there some other way — a host's
    # own `:lines` — has no sent text recorded, and is revoked by its own.
    defp pending_steer(state) do
      found =
        case state.tools.deferred_steer do
          {:pending, shown} ->
            {:deferred, shown}

          _other ->
            Enum.find_value(state.lines, fn
              {:steer, :pending, shown} -> {:row, shown}
              _row -> nil
            end)
        end

      with {where, shown} <- found do
        case List.keyfind(state.tools.sent_steers, shown, 0) do
          {^shown, sent} -> {where, shown, sent}
          nil -> {where, shown, shown}
        end
      end
    end

    # Cmd+Z, or the key bound to `:revoke_steer` (Alt+Z unless rebound),
    # takes back a steer that has not reached the model yet; with none
    # waiting, the key is the editor's.
    @doc false
    @spec revoke_steer(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def revoke_steer(event, state) do
      case pending_steer(state) do
        nil ->
          Composer.edit(event, state)

        steer ->
          {state, said} = take_back(state, steer)
          {:noreply, Flash.show(state, said)}
      end
    end

    # `/unsteer`, the same taking back for every terminal: Cmd+Z reaches the
    # screen only where the terminal reports the Command key. Typed, so it is
    # answered in the transcript under the line that asked.
    @doc false
    @spec unsteer(state :: TUI.t()) :: TUI.t()
    def unsteer(state) do
      case pending_steer(state) do
        nil ->
          Transcript.say(state, :lmx, Unsteer.nothing_waiting())

        steer ->
          {state, said} = take_back(state, steer)
          Transcript.say(state, :lmx, said)
      end
    end

    # Taken back from where it was drawn, and only that one: the session
    # drops one steer with the text, so the screen drops one row with it.
    defp take_back(state, {where, shown, sent}) do
      case revoke(state.session, sent) do
        :ok ->
          state =
            state
            |> undraw(where, shown)
            |> put_in([Access.key!(:tools), :sent_steers], sent_steers_without(state, shown))

          {state, Unsteer.revoked(:ok)}

        {:error, :already_sent} = sent ->
          {mark_steers(state, :sent), Unsteer.revoked(sent)}

        {:error, :not_running} = stopped ->
          {mark_steers(state, :not_sent), Unsteer.revoked(stopped)}
      end
    end

    defp undraw(state, :deferred, _shown), do: put_in(state.tools.deferred_steer, nil)

    defp undraw(state, :row, shown),
      do: %{state | lines: List.delete(state.lines, {:steer, :pending, shown})}

    defp sent_steers_without(state, shown), do: List.keydelete(state.tools.sent_steers, shown, 0)

    # A session that stopped marks its waiting steers undelivered
    # (`Lemieux.TUI.Lifecycle.session_down/2`), but its `:DOWN` can still be
    # in the mailbox behind the key or the `/unsteer` that asked. The call
    # then exits, and an exit here took the whole screen down; a steer whose
    # session is gone was simply never delivered.
    defp revoke(session, text) do
      Session.revoke_steer(session, text)
    catch
      :exit, _gone -> {:error, :not_running}
    end

    # A steer typed while tool calls were running waits under them, so it
    # lands after the results it was written in reply to.
    @doc false
    @spec flush_deferred_steer(TUI.t()) :: TUI.t()
    def flush_deferred_steer(%{tools: %{deferred_steer: nil}} = state), do: state

    def flush_deferred_steer(state) do
      {status, text} = state.tools.deferred_steer

      state
      |> put_in([Access.key!(:tools), :deferred_steer], nil)
      |> Transcript.append_rows([{:space, ""}, {:steer, status, text}, {:space, ""}])
    end

    # The next staged message goes when nothing else holds the screen: no
    # turn, no switch, no compaction, no modal waiting on the person, and no
    # opening question still to be answered (`History.hold/2`).
    @doc false
    @spec continue_queued(TUI.t()) :: reply()
    def continue_queued(%{history: %{queued: []}} = state), do: {:noreply, state}

    def continue_queued(state) do
      if state.conversation.busy? or state.resume.busy? or
           not is_nil(state.turn.compacting) or not is_nil(state.tools.question_flow) or
           not is_nil(state.tools.mcp_flow) or History.held?(state.history),
         do: {:noreply, state},
         else: submit_queued(state)
    end

    defp submit_queued(state) do
      draft = Composer.typed_value(state)
      [next | rest] = state.history.queued
      state = put_in(state.history.queued, rest)

      state =
        put_in(
          state.history.queued_selected,
          max(min(state.history.queued_selected, length(rest)), 1)
        )

      state =
        if state.history.revising,
          do: put_in(state.history.revising, max(state.history.revising - 1, 1)),
          else: state

      case sending(next, state) do
        {:noreply, sent} ->
          :ok = Editor.replace(sent.input, draft)
          continue_queued(sent)

        {:stop, stopped} ->
          {:stop, stopped}
      end
    end
  end
end
