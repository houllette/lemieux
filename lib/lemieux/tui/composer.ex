# The input box: what each key does to it, what the completion menus offer
# while somebody types, the `@` picker's directory listing, and Ctrl-C.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Composer do
    @moduledoc "Turns keys into edits, completions and history moves in a `Lemieux.TUI` input box."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Tabs
    alias Lemieux.Conversation
    alias Lemieux.Environment
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Appearance
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.CompletionMenu
    alias Lemieux.TUI.CompletionSources
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.FileIndex
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.History
    alias Lemieux.TUI.HistorySearch
    alias Lemieux.TUI.ImageAttachment
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Layout
    alias Lemieux.TUI.Lifecycle
    alias Lemieux.TUI.ModelChoices
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Notify
    alias Lemieux.TUI.Pager
    alias Lemieux.TUI.Pointer
    alias Lemieux.TUI.Policy
    alias Lemieux.TUI.ResourceIndex
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Submission
    alias Lemieux.TUI.Transcript

    # The textarea paints its own cursor cell, so the app's timer changes the
    # style of that cell instead of asking the terminal to blink its cursor.
    @cursor_blink_ms 500

    # A first Ctrl-C is a reversible warning rather than an accidental exit.
    # 750ms is long enough for an intentional double press and short enough
    # that the transient hint does not linger in the status line.
    @ctrl_c_window_ms 750

    # Typing `@` is the moment a person is thinking about files, so it is the moment
    # to re-attach the ones a tool has rewritten since — asking them to run
    # `/refresh` first is asking them to do the harness's job. Debounced, because a
    # path is typed one character at a time; quiet unless something changed.
    @refresh_debounce_ms :timer.seconds(10)

    @typep reply :: {:noreply, TUI.t()} | {:stop, TUI.t()}

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: reply()
    def key(event, state),
      do: act(Keys.action(state.status.keys, event), event, reveal_cursor(state))

    @doc false
    @spec reveal_cursor(TUI.t()) :: TUI.t()
    def reveal_cursor(state), do: put_in(state.terminal.cursor_blink.visible?, true)

    @doc false
    @spec start_cursor_blink(TUI.t()) :: TUI.t()
    def start_cursor_blink(state) do
      tick = make_ref()
      Process.send_after(self(), {:cursor_blink, tick}, @cursor_blink_ms)
      put_in(state.terminal.cursor_blink.tick, tick)
    end

    @doc false
    @spec blink(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def blink(%TUI{terminal: %{cursor_blink: %{tick: tick}}} = state, tick) do
      Process.send_after(self(), {:cursor_blink, tick}, @cursor_blink_ms)
      {:noreply, update_in(state.terminal.cursor_blink.visible?, &(!&1))}
    end

    def blink(state, _tick), do: {:noreply, state}

    # Shift-Tab steps the model picker's route tabs while the picker is open,
    # the slash menu's tabs while that has them, and the permission mode
    # otherwise; a host that bound it to something else keeps its binding
    # everywhere but those menus.
    @doc false
    @spec cycle_tab_or_edit(ExRatatui.Event.Key.t(), TUI.t()) :: reply()
    def cycle_tab_or_edit(event, state) do
      action = Keys.action(state.status.keys, event)

      if action in [:forward, :cycle_mode],
        do: cycle_tab(state, model_picker_tabs(state), command_tabs(state), action, event),
        else: act(action, event, state)
    end

    defp cycle_tab(state, [_ | _] = tabs, _command_tabs, _action, _event),
      do: {:noreply, %{state | model_tab: next_tab(tabs, state.model_tab), command_index: 0}}

    defp cycle_tab(state, [], %{tabs: tabs, tab: tab}, _action, _event),
      do: {:noreply, %{state | command_tab: next_tab(tabs, tab), command_index: 0}}

    defp cycle_tab(state, [], nil, action, event), do: act(action, event, state)

    defp next_tab(tabs, tab) do
      index = Enum.find_index(tabs, &(&1 == tab)) || 0
      Enum.at(tabs, rem(index + 1, length(tabs)))
    end

    # One clause per action in `Lemieux.TUI.Keys.actions/0`, then `:forward`.
    # The key event is passed along because some of these hand it to the
    # editor when there is nothing for them to do — `up` with no history is a
    # cursor movement, `alt-z` with no steer waiting is the editor's — and
    # what they hand over must be the key that was pressed, whatever it was
    # bound as.
    defp act(:interrupt, _event, state), do: interrupt(state)
    defp act(:submit, _event, state), do: complete_or_submit(state)
    defp act(:previous, event, state), do: navigate_or_history(event, state, -1)
    defp act(:next, event, state), do: navigate_or_history(event, state, 1)
    defp act(:scroll_up, _event, state), do: {:noreply, Pointer.scroll(state, Pointer.step())}
    defp act(:scroll_down, _event, state), do: {:noreply, Pointer.scroll(state, -Pointer.step())}

    # A page is a screenful less two rows, so the line that was at the edge is
    # still there to read across the jump — scrolling by exactly a screen
    # leaves nothing in common between the two, which is how a reader loses
    # their place.
    defp act(:page_up, _event, state), do: {:noreply, Pointer.scroll(state, Pointer.page(state))}

    defp act(:page_down, _event, state),
      do: {:noreply, Pointer.scroll(state, -Pointer.page(state))}

    defp act(:complete, event, state), do: complete_or_edit(event, state)
    defp act(:select_queued, event, state), do: History.select_queued(event, state)
    defp act(:revise_queued, _event, state), do: History.revise_queued(state)
    defp act(:unstage_queued, _event, state), do: History.unstage_queued(state)
    defp act(:revoke_steer, event, state), do: Submission.revoke_steer(event, state)

    defp act(:newline, _event, state) do
      :ok = ExRatatui.textarea_insert_str(state.input, "\n")
      {:noreply, edited(state)}
    end

    defp act(:pager, _event, state), do: {:noreply, Pager.open(state)}
    defp act(:history_search, _event, state), do: {:noreply, HistorySearch.open(state)}
    defp act(:external_editor, _event, state), do: {:noreply, external_edit(state)}
    defp act(:paste_image, _event, state), do: {:noreply, ImageAttachment.request(state)}
    defp act(:cycle_mode, _event, state), do: {:noreply, Policy.cycle(state)}
    defp act(:toggle_notifications, _event, state), do: {:noreply, Notify.toggle(state)}

    defp act(:dismiss, _event, state) do
      state = state |> History.restore_revising() |> Notices.dismiss()
      :ok = Editor.replace(state.input, "")

      {:noreply,
       %{
         state
         | command_menu?: false,
           command_index: 0,
           model_tab: "Automatic",
           command_tab: "Commands",
           selection: nil,
           history: History.browsing(state.history, nil)
       }}
    end

    # Everything the key map did not claim is editing, and the widget does it.
    # Keys are forwarded rather than interpreted, so the vocabulary is whatever
    # the underlying editor supports rather than whatever this file remembered
    # to list. A plain `c` is a letter somebody is typing, and a UI that quit
    # on it would be unusable.
    defp act(:forward, %ExRatatui.Event.Key{code: "enter"} = event, state) do
      if "shift" in event.modifiers do
        :ok = ExRatatui.textarea_insert_str(state.input, "\n")
        {:noreply, edited(state)}
      else
        edit(event, state)
      end
    end

    # Windows reports AltGr as Ctrl+Alt, so on a German, French or Polish
    # layout `@` arrives as `{"@", ["ctrl", "alt"]}` (and `ł` as
    # `{"ł", ["ctrl", "alt"]}`). The editor inserts a character only when
    # neither is held, which made `@`, `{`, `[`, `\\`, `|` and `~`
    # impossible to type. An ASCII letter or digit with both held is still a
    # shortcut, as it is everywhere else.
    defp act(:forward, %ExRatatui.Event.Key{code: code, modifiers: modifiers} = event, state) do
      if altgr_character?(code, modifiers) do
        :ok = ExRatatui.textarea_insert_str(state.input, code)
        {:noreply, edited(state)}
      else
        edit(event, state)
      end
    end

    # A module key map answered something outside the vocabulary. The key
    # goes to the editor, which is what an unbound key does, and the
    # transcript says so once per press: a host's bug, said where the host
    # is looking.
    defp act(
           {:unknown, other},
           %ExRatatui.Event.Key{code: code, modifiers: modifiers} = event,
           state
         ) do
      {:noreply, state} = edit(event, state)
      pressed = Keys.describe({Enum.sort(modifiers), String.downcase(code)})

      {:noreply,
       Transcript.say(
         state,
         :lmx,
         "keys: #{inspect(state.status.keys)} answered #{inspect(other)} for #{pressed}, " <>
           "which is not an action · the key went to the editor"
       )}
    end

    # Ctrl-C cancels a running turn; with nothing running, the first press arms
    # an exit and a second inside the window leaves.
    @doc false
    @spec interrupt(TUI.t()) :: reply()
    def interrupt(%TUI{conversation: %{busy?: true}} = state) do
      {conversation, effects} = Conversation.input(state.conversation, "/cancel")
      Effects.run(%{state | conversation: conversation, exit_armed: nil}, effects)
    end

    def interrupt(%TUI{exit_armed: {_token, expires_at}} = state) do
      if System.monotonic_time(:millisecond) <= expires_at do
        Lifecycle.stopping(state)
      else
        arm_exit(state)
      end
    end

    def interrupt(state), do: arm_exit(state)

    defp arm_exit(state) do
      token = make_ref()
      expires_at = System.monotonic_time(:millisecond) + @ctrl_c_window_ms
      Process.send_after(self(), {:ctrl_c_expired, token}, @ctrl_c_window_ms)

      {:noreply, %{state | exit_armed: {token, expires_at}}}
    end

    @doc false
    @spec exit_expired(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def exit_expired(%TUI{exit_armed: {token, _expires}} = state, token),
      do: {:noreply, %{state | exit_armed: nil}}

    def exit_expired(state, _token), do: {:noreply, state}

    # Pasted text goes in whole. Where a modal owns the keyboard, it goes in
    # only where the modal takes free text, and nowhere while a session is
    # still starting.
    @doc false
    @spec paste(event :: term(), TUI.t()) :: {:noreply, TUI.t()}
    # An empty paste is what several terminals send for a clipboard holding
    # an image rather than text; it is the image, then, that was meant.
    def paste(%ExRatatui.Event.Paste{content: ""}, state),
      do: {:noreply, ImageAttachment.request(state)}

    def paste(%ExRatatui.Event.Paste{content: content}, state)
        when is_binary(content) and not is_nil(state.tools.question_flow) do
      if state.tools.question_flow.other? or not is_nil(state.tools.question_flow.note_option),
        do: :ok = ExRatatui.textarea_insert_str(state.input, line_endings(content))

      {:noreply, state}
    end

    def paste(
          %ExRatatui.Event.Paste{content: content},
          %{tools: %{mcp_flow: %{mode: :add, questionnaire: %{other?: true}}}} = state
        )
        when is_binary(content) do
      :ok = ExRatatui.textarea_insert_str(state.input, line_endings(content))
      {:noreply, state}
    end

    def paste(%ExRatatui.Event.Paste{}, %{tools: %{mcp_flow: flow}} = state)
        when not is_nil(flow),
        do: {:noreply, state}

    def paste(%ExRatatui.Event.Paste{content: content}, state)
        when is_binary(content) do
      :ok = ExRatatui.textarea_insert_str(state.input, line_endings(content))

      {:noreply, edited(reveal_cursor(state))}
    end

    def paste(_event, state), do: {:noreply, state}

    # Terminals disagree about the line ending inside a bracketed paste:
    # xterm.js (VS Code), VTE (GNOME Terminal), xterm and tmux's
    # `paste-buffer` send a bare CR per line, a Windows clipboard CRLF. The
    # editor breaks lines only on LF, so a CR-separated paste arrived as one
    # run-on line with invisible carriage returns in it, was echoed joined,
    # and reached the model that way.
    @doc false
    @spec line_endings(content :: String.t()) :: String.t()
    def line_endings(content), do: String.replace(content, ~r/\r\n?/, "\n")

    defp navigate_or_history(event, state, by) do
      case completions(state) do
        [] ->
          navigate_draft_or_history(event, state, by)

        matches ->
          {:noreply,
           %{state | command_index: Integer.mod(state.command_index + by, length(matches))}}
      end
    end

    defp navigate_draft_or_history(event, %{history: %{index: index}} = state, by)
         when not is_nil(index),
         do: History.step(event, state, by)

    defp navigate_draft_or_history(%ExRatatui.Event.Key{modifiers: modifiers} = event, state, by) do
      if "alt" in modifiers or
           Layout.input_height(typed_value(state), Screen.panes(state).input.width) <= 3 do
        History.step(event, state, by)
      else
        before = ExRatatui.textarea_cursor(state.input)
        {:noreply, moved} = edit(event, state)

        if ExRatatui.textarea_cursor(state.input) == before,
          do: History.step(event, moved, by),
          else: {:noreply, moved}
      end
    end

    defp complete_or_edit(_event, %{history: %{revising: number}} = state)
         when not is_nil(number),
         do: History.queue_draft(state)

    defp complete_or_edit(_event, %{conversation: %{busy?: true}} = state) do
      if String.trim(typed_value(state)) == "",
        do: {:noreply, state},
        else: History.queue_draft(state)
    end

    defp complete_or_edit(event, state), do: complete_or_edit_regular(event, state)

    defp complete_or_edit_regular(event, state) do
      case completions(state) do
        [] ->
          accept_followup(event, state)

        matches ->
          complete(state, matches)
      end
    end

    # Tab means "take what is being offered". With nothing in the box that is
    # the follow-up hint, which is the only thing on screen it could mean —
    # and with anything in the box Tab is a tab again.
    defp accept_followup(event, state) do
      case Screen.followup(state) do
        nil ->
          edit(event, state)

        suggestion ->
          :ok = Editor.replace(state.input, suggestion)

          {:noreply, edited(state)}
      end
    end

    defp complete_or_submit(%{history: %{revising: number}} = state)
         when not is_nil(number),
         do: History.queue_draft(state)

    defp complete_or_submit(%{conversation: %{busy?: true}} = state), do: Submission.submit(state)

    defp complete_or_submit(state) do
      case completions(state) do
        [] -> continue_or_submit(state)
        matches -> complete_and_maybe_submit(state, matches)
      end
    end

    # A line ending in a backslash continues on the next one, as it does in a
    # shell: the fallback for a terminal that sends Shift+Enter as a plain
    # Enter, where the key table's `ctrl-j` is the other way to a newline.
    defp continue_or_submit(state) do
      typed = typed_value(state)

      if String.ends_with?(typed, "\\") do
        :ok = Editor.replace(state.input, String.replace_suffix(typed, "\\", "\n"))
        {:noreply, edited(state)}
      else
        Submission.submit(state)
      end
    end

    # Ctrl-G. The editor callback blocks this process until the editor
    # exits, deliberately: the terminal is the editor's until then, and this
    # process is also the one that would otherwise be reading its keys. See
    # `Lemieux.TUI.ExternalEditor`.
    defp external_edit(%TUI{terminal: %{editor: nil}} = state),
      do: Flash.show(state, "an external editor needs a local terminal")

    defp external_edit(state) do
      case state.terminal.editor.(typed_value(state)) do
        # An editor saves whatever encoding it was set to, and the input box
        # raises on bytes that are not UTF-8 — after `Editor.replace/2` has
        # cleared the draft. Repaired here rather than in
        # `Lemieux.TUI.ExternalEditor`, because a host may hand the screen an
        # editor of its own.
        {:ok, edited} ->
          :ok = Editor.replace(state.input, String.replace_invalid(edited))
          state |> edited() |> Screen.repaint()

        {:error, reason} ->
          state |> Screen.repaint() |> Flash.show("editor: #{reason}")
      end
    end

    # Enter chooses the highlighted action in one press. A command that needs
    # an argument opens its next menu; a prompt reference only fills the draft.
    # Tab still fills a choice without running it.
    defp complete_and_maybe_submit(state, matches) do
      completion = selected_completion(state, matches)
      {:noreply, completed} = apply_completion(state, completion)

      if Map.get(completion, :opens_arguments?, false) or
           not Map.get(completion, :submit?, true),
         do: {:noreply, completed},
         else: Submission.submit(completed)
    end

    defp complete(state, matches),
      do: apply_completion(state, selected_completion(state, matches))

    defp selected_completion(state, matches),
      do: Enum.at(matches, Integer.mod(state.command_index, length(matches)))

    defp apply_completion(state, completion) do
      :ok = Editor.replace(state.input, completion.value)

      {:noreply, %{edited(state) | command_menu?: Map.get(completion, :opens_arguments?, false)}}
    end

    defp altgr_character?(code, modifiers) when is_binary(code) and is_list(modifiers) do
      "ctrl" in modifiers and "alt" in modifiers and String.length(code) == 1 and
        String.printable?(code) and not String.match?(code, ~r/\A[A-Za-z0-9 ]\z/)
    end

    defp altgr_character?(_code, _modifiers), do: false

    @doc false
    @spec edit(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def edit(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state) do
      case editor_key(code, modifiers) do
        {code, modifiers} ->
          :ok = ExRatatui.textarea_handle_key(state.input, code, modifiers)
          {:noreply, edited(state)}

        :ignore ->
          {:noreply, state}
      end
    end

    # The editor's own bindings were written for an application, and Ctrl-U
    # is undo there. At a prompt it deletes back to the start of the line, and
    # iTerm2, Ghostty, Alacritty and VS Code send it for Cmd-Backspace, so
    # Cmd-Backspace undid instead (#23): each press took back one typed
    # character, and held after deleting it brought the deleted text back.
    # Ctrl-U now deletes to the line's start, as the editor's Ctrl-J does,
    # and undo moves to Ctrl-Z, which a raw-mode terminal delivers as a key
    # rather than a suspend. A Cmd-Backspace reported as itself, which only
    # the kitty keyboard protocol does, gets the same treatment: the editor
    # ignores the Command key and would delete one character.
    defp editor_key("u", ["ctrl"]), do: {"j", ["ctrl"]}
    defp editor_key("z", ["ctrl"]), do: {"u", ["ctrl"]}

    defp editor_key("backspace", modifiers) do
      if "super" in modifiers or "meta" in modifiers,
        do: {"j", ["ctrl"]},
        else: {"backspace", modifiers}
    end

    defp editor_key(code, modifiers) do
      if stray_character?(code, modifiers), do: :ignore, else: {code, modifiers}
    end

    # The editor types any one character pressed with neither Ctrl nor Alt,
    # whatever else is held and whatever the character is. So a Command,
    # Hyper or Meta key the terminal reported — Cmd-K, Cmd-C — typed its
    # letter, and a stray control character landed in the draft as an
    # invisible byte. A character is typed only with nothing but Shift held,
    # and only when it is not a control character; anything else the key map
    # and the editor both pass over does nothing.
    defp stray_character?(code, modifiers) do
      String.length(code) == 1 and "ctrl" not in modifiers and "alt" not in modifiers and
        (modifiers -- ["shift"] != [] or control_character?(code))
    end

    # Line feed, carriage return and tab are the control characters that are
    # text: the editor breaks the line on the first two and keeps the third.
    # `String.printable?/1` is not the test, because it counts ESC and BEL as
    # printable.
    defp control_character?(code) when code in ["\n", "\r", "\t"], do: false
    defp control_character?(code), do: String.match?(code, ~r/\p{Cc}/u)

    # The input box changed: the menus reopen from the top, history browsing
    # ends, and the `@` picker catches up with the path being typed.
    @doc false
    @spec edited(TUI.t()) :: TUI.t()
    def edited(state) do
      typed = typed_value(state)
      model_tab = if String.starts_with?(typed, "/model "), do: state.model_tab, else: "Automatic"
      # The chosen slash tab holds while the name is still being typed, so
      # narrowing within it works; a completed command, or anything else,
      # puts the next menu back on the default tab.
      command_tab = if command_prefix?(typed), do: state.command_tab, else: "Commands"

      %{
        state
        | command_menu?: true,
          command_index: 0,
          model_tab: model_tab,
          command_tab: command_tab,
          history: History.browsing(state.history, nil)
      }
      |> listed()
      |> refreshed()
    end

    @doc false
    @spec typed_value(TUI.t()) :: String.t()
    def typed_value(state), do: ExRatatui.textarea_get_value(state.input)

    defp refreshed(%TUI{session: nil} = state), do: state
    defp refreshed(%TUI{conversation: %{busy?: true}} = state), do: state

    defp refreshed(state) do
      now = state.clock.()

      if referencing?(state) and due?(state.references.refreshed_at, now) do
        app = self()
        session = state.session

        Task.start(fn -> send(app, {:refresh_result, :automatic, attachments(session)}) end)

        put_in(state.references.refreshed_at, now)
      else
        state
      end
    end

    defp referencing?(state), do: match?({:reference, _path}, typed_path(typed_value(state)))

    # Nobody asked for this one, so a session that went away between the
    # keystroke and the task is not a crash report. The typed `/refresh` is a
    # request and keeps the `GenServer.call` exit that says the session died.
    defp attachments(session) do
      Session.refresh(session)
    catch
      :exit, _reason -> {:error, :not_running}
    end

    defp due?(nil, _now), do: true
    defp due?(refreshed_at, now), do: now - refreshed_at >= @refresh_debounce_ms

    # The one effect on the key path. It runs at most once per directory the
    # reference moves through, not once per keystroke: typing further into a
    # directory already listed matches the first clause and reads nothing.
    defp listed(%TUI{references: %{cwd: nil}} = state), do: state

    defp listed(state) do
      case typed_path(typed_value(state)) do
        {:reference, path} ->
          state |> list_directory(CompletionSources.directory(path)) |> fuzzy(path)

        {_kind, path} ->
          list_directory(state, CompletionSources.directory(path))

        nil ->
          put_in(state.references.fuzzy, nil)
      end
    end

    # A reference with something typed after the `@` searches every file,
    # not just the directory named so far; see `Lemieux.TUI.FileIndex`. The
    # matches are computed here, on the key, and kept for the menu, which is
    # drawn at frame rate and must not rank twenty thousand paths per frame.
    defp fuzzy(state, path) do
      case CompletionSources.fuzzy_query(path) do
        nil ->
          put_in(state.references.fuzzy, nil)

        query ->
          references =
            state.references
            |> FileIndex.ensure(state.clock.())
            |> ResourceIndex.ensure(state.session)

          matches =
            case references.index do
              %{files: files} -> FileIndex.match(files, query)
              _loading -> []
            end

          # A connected server's resources, `@server:uri`, ranked the same
          # way beside the files; see `Lemieux.TUI.ResourceIndex`.
          fuzzy = %{
            query: path,
            matches: matches,
            resources: ResourceIndex.match(references, query)
          }

          %{state | references: %{references | fuzzy: fuzzy}}
      end
    end

    @doc false
    @spec resources_listed(TUI.t(), pid(), [ResourceIndex.item()]) :: TUI.t()
    def resources_listed(state, session, items) do
      state = %{
        state
        | references: ResourceIndex.loaded(state.references, state.session, session, items)
      }

      # The same re-reading `indexed/3` does, so a menu open over an `@` query
      # gains the resources the moment they arrive.
      if state.references.cwd, do: listed(state), else: state
    end

    @doc false
    @spec refresh_resources(TUI.t()) :: TUI.t()
    def refresh_resources(state),
      do: %{state | references: ResourceIndex.refresh(state.references, state.session)}

    @doc false
    @spec indexed(TUI.t(), Path.t(), [String.t()]) :: TUI.t()
    def indexed(state, cwd, files) do
      state = %{
        state
        | references: FileIndex.loaded(state.references, cwd, files, state.clock.())
      }

      if state.references.cwd, do: listed(state), else: state
    end

    defp list_directory(%TUI{references: %{directory: directory}} = state, directory),
      do: state

    defp list_directory(state, directory) do
      entries =
        case Environment.list_dir(environment(state), state.references.cwd, directory) do
          {:ok, entries} -> entries
          # A directory that is not there yet is not an error worth showing
          # somebody mid-word; the menu simply has nothing to offer.
          {:error, _reason} -> []
        end

      %{state | references: %{state.references | directory: directory, entries: entries}}
    end

    # The tests build a state with `struct!/2` rather than through `new/1`, so
    # the default belongs somewhere a struct literal reaches.
    defp environment(%TUI{references: %{environment: nil}}), do: Environment.local()
    defp environment(%TUI{references: %{environment: environment}}), do: environment

    defp typed_path(value), do: CompletionSources.typed_path(value)

    # Query matching remains in this app, which owns the editor and session.
    # The bounded menu is a rendering adapter over those prepared choices.
    @doc false
    @spec autocomplete(TUI.t(), map()) :: list()
    def autocomplete(state, panes) do
      matches = completions(state)

      CompletionMenu.render(
        matches,
        panes,
        tab_options(state) ++
          [
            selected: state.command_index,
            gap_after: model_completion_gap_after(state, matches),
            accent: Screen.accent(state),
            theme: Screen.theme(state)
          ]
      )
    end

    # The tab row the menu draws, if any: the model picker's routes while
    # `/model ` is typed, the slash menu's sources while a bare `/NAME` is.
    defp tab_options(state) do
      case {model_picker_tabs(state), command_tabs(state)} do
        {[_ | _] = tabs, _commands} ->
          [tabs: tabs, tab: state.model_tab, tab_rows: state.catalog.model_tab_rows]

        {[], %{tabs: tabs, tab: tab, rows: rows}} ->
          [
            tabs: tabs,
            tab: tab,
            tab_rows: rows,
            tab_label: & &1,
            noun: if(tab == "Commands", do: "commands", else: "skills"),
            tab_hint: "shift-tab switches tabs"
          ]

        {[], nil} ->
          [tabs: [], tab: nil, tab_rows: 0]
      end
    end

    @doc false
    @spec command_definitions(TUI.t()) :: list()
    def command_definitions(state),
      do: CompletionSources.command_definitions(completion_context(state))

    defp completions(%TUI{command_menu?: false}), do: []

    defp completions(state),
      do: CompletionSources.matches(typed_value(state), completion_context(state))

    defp completion_context(state) do
      %{
        catalog: state.catalog,
        model_tab: state.model_tab,
        command_tab: state.command_tab,
        conversation: state.conversation,
        skills: state.skills,
        references: state.references,
        resume: state.resume,
        id: state.id,
        themes: Screen.themes(state),
        tool_statuses: Choices.tool_statuses(state),
        command_policy: Choices.command_policy(state),
        accent_names: Appearance.accents()
      }
    end

    defp model_picker_tabs(%TUI{command_menu?: false}), do: []

    defp model_picker_tabs(state) do
      if String.starts_with?(ExRatatui.textarea_get_value(state.input), "/model "),
        do: state.catalog.model_tabs,
        else: []
    end

    # The slash menu's tabs (`Lemieux.TUI.CompletionSources.command_tabs/2`)
    # while the box holds a bare `/NAME` and nothing after it.
    defp command_tabs(%TUI{command_menu?: false}), do: nil

    defp command_tabs(state) do
      value = typed_value(state)

      if command_prefix?(value),
        do: CompletionSources.command_tabs(completion_context(state), value),
        else: nil
    end

    defp command_prefix?(value), do: Regex.match?(~r/^\s*\/[^\s]*$/, value)

    defp model_completion_gap_after(state, matches) do
      if ExRatatui.textarea_get_value(state.input) == "/model " do
        matches
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_index(fn [first, second] ->
          Map.get(first, :personal?, false) and not Map.get(second, :personal?, false)
        end)
      end
    end

    # The tab under a click, if the click was on the tab row the completion
    # menu drew: the model picker's route, or the slash menu's source.
    @doc false
    @spec tab_at(TUI.t(), ExRatatui.Event.Mouse.t()) ::
            {:ok, :model_tab | :command_tab, String.t()} | nil
    def tab_at(state, %ExRatatui.Event.Mouse{x: x, y: y}) do
      state
      |> Screen.panes()
      |> then(&autocomplete(state, &1))
      |> Enum.find_value(fn
        {%Tabs{}, %Rect{} = area} when y == area.y and x >= area.x ->
          case {model_picker_tabs(state), command_tabs(state)} do
            {[_ | _] = tabs, _commands} ->
              tab_at_x(tabs, &ModelChoices.tab_label/1, x - area.x, :model_tab)

            {[], %{tabs: tabs}} ->
              tab_at_x(tabs, & &1, x - area.x, :command_tab)

            {[], nil} ->
              nil
          end

        _other ->
          nil
      end)
    end

    defp tab_at_x(tabs, label, x, field) do
      Enum.reduce_while(tabs, {0, nil}, fn tab, {offset, _selected} ->
        width = String.length(label.(tab)) + 2

        if x >= offset and x < offset + width,
          do: {:halt, {offset, tab}},
          else: {:cont, {offset + width + 1, nil}}
      end)
      |> elem(1)
      |> case do
        nil -> nil
        tab -> {:ok, field, tab}
      end
    end
  end
end
