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
    alias Lemieux.TUI.SkillLoading
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

    defp sending_ordinary(typed, %TUI{references: %{skill_load: load}} = state)
         when not is_nil(load) do
      if String.trim(typed) in ["/quit", "/exit", "/new"] or
           String.starts_with?(String.trim(typed), "/resume"),
         do: send_input(typed, SkillLoading.cancel(state)),
         else: {:noreply, Flash.show(state, "loading skill · wait before sending another prompt")}
    end

    defp sending_ordinary(typed, %{conversation: %{busy?: true}} = state) do
      if state.tools.pending_steer && not String.starts_with?(String.trim_leading(typed), "/"),
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
      {conversation, effects} = conversation_input(state, typed)
      effects = command_effects(typed, effects)

      case Enum.find(effects, &match?({:steer, _text}, &1)) do
        {:steer, text} ->
          queue_steer(state, conversation, typed, text)

        nil ->
          state
          |> record_input(conversation, typed)
          |> echo_input(typed, effects)
          |> Effects.run(effects)
      end
    end

    defp queue_steer(state, conversation, typed, text) do
      case enqueue_steer(state.session, text) do
        {:ok, id} ->
          state = record_input(state, conversation, typed)
          {:noreply, put_in(state.tools.pending_steer, %{id: id, text: typed})}

        {:error, :idle} ->
          {:noreply, Flash.show(state, "turn ended · Enter sends your draft as a new prompt")}

        {:error, :not_running} ->
          {:noreply, Flash.show(state, "session stopped before the steer was queued")}
      end
    end

    defp enqueue_steer(session, text) do
      Session.steer(session, text, :while_running)
    catch
      :exit, _gone -> {:error, :not_running}
    end

    defp record_input(state, conversation, typed) do
      :ok = ExRatatui.textarea_set_value(state.input, "")

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
    end

    # While startup connections run, asking the session waits for the
    # slowest server; what the screen was told stands in, and the manager
    # lists the servers as connecting. Once they have settled the session
    # answers at once.
    defp mcp_statuses(%TUI{session_view: %{mcp_ready?: false}} = state),
      do: MCPStatus.statuses(state)

    defp mcp_statuses(state), do: Session.mcp_status(state.session)

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
          {state.conversation, [{:load_skill, skill, arguments}]}

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
      if Enum.any?(effects, &tools_effect?/1),
        do: state,
        else: echo_chat_input(state, typed, effects)
    end

    defp echo_chat_input(state, typed, effects) do
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

        true ->
          Transcript.say(state, :you, typed)
      end
    end

    defp tools_effect?(:tools_status), do: true
    defp tools_effect?({action, _names}) when action in [:enable_tools, :disable_tools], do: true
    defp tools_effect?(_effect), do: false

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

    # A request already in the mailbox may predate the steer. The request
    # snapshot identifies the exact entries the parent was given.
    @doc false
    @spec deliver_steer(TUI.t(), map()) :: TUI.t()
    def deliver_steer(%{tools: %{pending_steer: %{id: id}}} = state, payload) do
      if id in Map.get(payload, "entry_ids", []), do: settle_steer(state, :sent), else: state
    end

    def deliver_steer(state, _payload), do: state

    @doc false
    @spec settle_steer(TUI.t(), :sent | :not_sent | :revoked) :: TUI.t()
    def settle_steer(%{tools: %{pending_steer: nil}} = state, _status), do: state

    def settle_steer(%{tools: %{pending_steer: %{text: text}}} = state, status) do
      state
      |> put_in([Access.key!(:tools), :pending_steer], nil)
      |> Transcript.append_rows([{:space, ""}, {:steer, status, text}, {:space, ""}])
    end

    @doc false
    @spec revoke_steer(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def revoke_steer(event, state) do
      case state.tools.pending_steer do
        nil ->
          Composer.edit(event, state)

        steer ->
          {state, said} = take_back(state, steer)
          {:noreply, Flash.show(state, said)}
      end
    end

    @doc false
    @spec unsteer(state :: TUI.t()) :: TUI.t()
    def unsteer(state) do
      case state.tools.pending_steer do
        nil ->
          Transcript.say(state, :lmx, Unsteer.nothing_waiting())

        steer ->
          {state, said} = take_back(state, steer)
          Transcript.say(state, :lmx, said)
      end
    end

    defp take_back(state, %{id: id}) do
      case revoke(state.session, id) do
        :ok ->
          {settle_steer(state, :revoked), Unsteer.revoked(:ok)}

        {:error, :already_sent} ->
          {state, "steer is already in a prepared request"}

        {:error, :not_running} = stopped ->
          {settle_steer(state, :not_sent), Unsteer.revoked(stopped)}
      end
    end

    defp revoke(session, id) do
      Session.revoke_steer(session, {:id, id})
    catch
      :exit, _gone -> {:error, :not_running}
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
