# `Lemieux.Conversation` effects: the few a screen performs differently — what
# it draws and the menus it keeps — and the shared rest, performed through
# `Lemieux.Conversation.Dispatch` with this screen as the host.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Effects do
    @moduledoc "Performs `Lemieux.Conversation` effects for a `Lemieux.TUI`."

    alias Lemieux.CLI.Feedback
    alias Lemieux.Context
    alias Lemieux.Conversation
    alias Lemieux.Conversation.Columns
    alias Lemieux.Conversation.Command.Help, as: HelpCommand
    alias Lemieux.Conversation.Dispatch
    alias Lemieux.ModelSpec
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Appearance
    alias Lemieux.TUI.Art
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Clipboard
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.DiffPanel
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Lifecycle
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Submission
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.Turn
    alias Lemieux.TUI.Updates

    @typep reply :: {:noreply, TUI.t()} | {:stop, TUI.t()}

    # Effects run in order, and `:quit` ends the app — so this halts rather
    # than running to the end and checking afterwards.
    @doc false
    @spec run(TUI.t(), list()) :: reply()
    def run(state, effects) do
      Enum.reduce_while(effects, {:noreply, state}, fn effect, {:noreply, state} ->
        run_effect(state, effect)
      end)
    end

    defp run_effect(state, effect) do
      decision =
        if Conversation.command_action?(state.conversation, effect),
          do: Conversation.command_decision(Choices.command_policy(state), effect),
          else: :allow

      apply_command_decision(state, effect, decision)
    end

    defp apply_command_decision(state, effect, :allow) do
      case perform(state, effect) do
        {:stop, _state} = stop -> {:halt, stop}
        state -> {:cont, {:noreply, state}}
      end
    end

    defp apply_command_decision(state, _effect, {:deny, message}),
      do: {:cont, {:noreply, Transcript.say(state, :lmx, message)}}

    defp perform(state, :help) do
      help = Conversation.help(state.conversation, Choices.command_policy(state))
      commands = Conversation.commands(state.conversation, Choices.command_policy(state))

      skills =
        state
        |> Composer.command_definitions()
        |> Enum.reject(fn command -> Enum.any?(commands, &(&1.name == command.name)) end)

      skill_help =
        case skills do
          [] -> ""
          skills -> "\n\nSkills\n" <> (skills |> Enum.map(&skill_help/1) |> columns())
        end

      keys = key_help(state.status.keys)

      Transcript.say(
        state,
        :lmx,
        Enum.join([help <> skill_help, keys, HelpCommand.links()], "\n\n")
      )
    end

    defp perform(state, :context_status), do: Transcript.append_rows(state, context_rows(state))
    defp perform(state, :diff), do: DiffPanel.open(state)

    # Only the TUI's default copy projects visualizations; source copying and
    # non-terminal hosts retain the transcript's original Markdown/JSON.
    defp perform(state, :copy) do
      host = host(state)
      clipboard = host.clipboard
      width = Screen.columns(state)
      theme = Screen.theme(state)

      projected =
        if clipboard,
          do: fn source -> clipboard.(Clipboard.presentation(source, width, theme)) end

      Dispatch.perform(state, %{host | clipboard: projected}, :copy)
    end

    defp perform(state, :model_status) do
      available = length(state.catalog.models)
      current = ModelSpec.model_id(state.conversation.model) || state.conversation.model

      Transcript.say(
        state,
        :lmx,
        "model: #{current} · #{available} available for the current provider · " <>
          "type /model MODEL (Tab completes)"
      )
    end

    defp perform(state, :provider_status) do
      current =
        Map.get(state.conversation, :provider) || ModelSpec.provider(state.conversation.model)

      Transcript.say(
        state,
        :lmx,
        "provider: #{current} · #{length(state.catalog.providers)} available · " <>
          "type /provider PROVIDER (Tab completes)"
      )
    end

    defp perform(state, :reasoning_effort_status) do
      current = Map.get(state.conversation, :reasoning_effort, "default")

      case state.catalog.efforts do
        # Phrased about the levels rather than about the model, because a
        # gateway route is one of the things that can be named here: an empty
        # list then means no level is safe across every candidate the route
        # may pick, which is not a claim about the profile that was typed.
        [] ->
          Transcript.say(
            state,
            :lmx,
            "no reasoning effort levels are offered for #{state.conversation.model}"
          )

        efforts ->
          Transcript.say(
            state,
            :lmx,
            "effort: #{current} · #{length(efforts)} available · " <>
              "type /effort LEVEL (Tab completes)"
          )
      end
    end

    defp perform(state, :name_status), do: Appearance.name_status(state)
    defp perform(state, {:set_name, "default"}), do: Appearance.rename(state, nil)
    defp perform(state, {:set_name, name}), do: Appearance.rename(state, name)
    defp perform(state, :colour_status), do: Appearance.colour_status(state)
    defp perform(state, {:set_colour, colour}), do: Appearance.set_colour(state, colour)
    defp perform(state, :theme_status), do: Appearance.theme_status(state)
    defp perform(state, {:set_theme, name}), do: Appearance.set_theme(state, name)
    defp perform(state, :toggle_elixir_mode), do: Choices.toggle_elixir_mode(state)
    defp perform(state, :habs), do: Lifecycle.start_habs(state)
    defp perform(state, :resume_status), do: Transcript.say(state, :lmx, resumable(state, :here))

    defp perform(state, {:resume_list, :all}),
      do: Transcript.say(state, :lmx, resumable(state, :all))

    defp perform(state, :new), do: Lifecycle.new_session(state)
    defp perform(state, {:resume, id}), do: Lifecycle.resume_session(state, id)
    defp perform(state, :quit), do: Lifecycle.stopping(state)
    defp perform(state, :unsteer), do: Submission.unsteer(state)
    defp perform(state, :update), do: Updates.request(state)

    # Everything else — the session calls, `:say`, `:write` — is the table both
    # front ends share, and `Lemieux.Conversation.Dispatch` performs it through
    # the callbacks in `host/1`. What is above is only what a screen does
    # differently: what it draws, and the menus it keeps. `:ready` and `:idle`
    # come back from the dispatcher untouched, which is right: they are a
    # terminal reprinting its prompt, and a screen redrawn after every message
    # has nothing to do with either.
    defp perform(state, effect), do: Dispatch.perform(state, host(state), effect)

    # What this screen is to the shared dispatcher. Built per effect rather
    # than kept in the struct: it closes over `self()` and over this module's
    # own functions, and a closure stored in the state would outlive a hot
    # upgrade of the code it points into — `Lemieux.TUI.Callbacks` holds the
    # functions the state does store, for exactly that reason.
    defp host(state) do
      app = self()

      Dispatch.new(
        session: state.session,
        id: state.id,
        say: fn state, text -> Transcript.say(state, :lmx, text) end,
        write: &write/2,
        fold: &fold/2,
        # Off the render loop:
        # `handle_event/2` runs in the process that draws and polls input, so
        # blocking there is a frozen UI with nothing on screen to say why. The
        # answer comes back through `handle_info/2`, which hands it to
        # `answer/2`.
        run: fn state, work ->
          :ok = start_work(state, answering(app, state.session, work))

          state
        end,
        react: &react/2,
        clipboard: state.terminal.clipboard,
        discovered: state.catalog.discovered,
        discover: state.catalog.discover,
        preferred_models: Choices.selection_preferences(state),
        preferred_efforts: state.catalog.preferred_efforts,
        feedback: Feedback,
        feedback_opts: state.feedback_opts,
        commands: state.conversation.commands,
        # The session's own environment, so `!command`, `/diff` and `/undo`
        # run under the sandbox and credential policy its tools do.
        environment: state.references.environment,
        cwd: state.references.cwd,
        # Read with `Map.get/2`: a screen built by a host that supplied
        # neither has no key to read, and has neither feature.
        permissions: Map.get(state.tool_choices, :permissions),
        checkpoints: Map.get(state.tool_choices, :checkpoints),
        export_dir: export_dir(state.feedback_opts)
      )
    end

    # Work `:run` sends off. Under the screen's task supervisor (the runtime's,
    # in `lmx`), so work still in flight belongs to something and stops with
    # it; linked to the screen where a host gave it none, as `/new`'s stop of
    # the previous session is (`Lemieux.TUI.Lifecycle`). It was a bare
    # `Task.start`: owned by nothing, it outlived the screen and the runtime
    # whenever its call never returned.
    defp start_work(%TUI{resume: %{task_supervisor: supervisor}}, work)
         when not is_nil(supervisor) do
      {:ok, _task} = Task.Supervisor.start_child(supervisor, work)
      :ok
    end

    defp start_work(_state, work) do
      {:ok, _task} = Task.start_link(work)
      :ok
    end

    # The answer goes to the screen. A session that died under the call —
    # `/new` or `/resume` stopped it, or it was killed — has no answer to
    # give, and the screen hears of the death from its own monitor; so that
    # exit ends the task quietly. It used to crash the task, which logged
    # "[error] Task … terminating" for an answer nobody was waiting for. Any
    # other exit — a timeout on a live session — is still the task's to
    # crash with.
    defp answering(app, session, work) do
      fn ->
        try do
          send(app, work.())
        catch
          :exit, reason ->
            if gone?(session), do: :ok, else: :erlang.raise(:exit, reason, __STACKTRACE__)
        end
      end
    end

    defp gone?(session) when is_pid(session) and node(session) == node(),
      do: not Process.alive?(session)

    defp gone?(_session), do: false

    # Exports go beside the sessions directory, so a host — or a test — that
    # moved one moves the other, as the feedback ledger does.
    defp export_dir(feedback_opts) do
      case Keyword.get(feedback_opts, :sessions_dir) do
        dir when is_binary(dir) -> Path.join(Path.dirname(Path.expand(dir)), "exports")
        _default -> nil
      end
    end

    # What the screen does about what the dispatcher did. Each is the residue
    # the shared clause used to end with: the spinner, a menu that is stale, a
    # pane that is showing what the model can no longer see.
    defp react(state, :turn_started), do: Turn.start_processing(state)

    defp react(state, {:reflecting, mode}),
      do: state |> Transcript.say(:lmx, reflecting(mode)) |> Turn.start_processing()

    # The screen is cleared with the context: a pane still showing the
    # conversation the model can no longer see is the most misleading thing
    # this UI could draw. `lmx log` still has all of it.
    defp react(state, :cleared), do: Lifecycle.cleared(state)

    defp react(state, {:model_set, selected}) do
      state
      |> Choices.refresh_choices(ModelSpec.provider(selected))
      |> Choices.open_effort_completions()
    end

    defp react(state, {:provider_set, selected}),
      do: Choices.open_model_completions(state, ModelSpec.provider(selected))

    defp react(state, {:reasoning_effort_set, _effort}), do: Choices.refresh_choices(state)
    defp react(state, {:tool_statuses, statuses}), do: Choices.put_tool_statuses(state, statuses)

    defp react(state, :tools_changed),
      do: Choices.put_tool_statuses(state, Session.tool_status(state.session))

    defp react(state, {:mcp_statuses, statuses}) do
      state
      |> Choices.put_mcp_names(statuses)
      |> put_in([Access.key!(:tools), :mcp_flow], %{
        statuses: statuses,
        selected: 0,
        mode: :list,
        questionnaire: nil,
        notice: nil,
        busy?: false,
        confirm_remove: nil,
        confirm_delete: nil
      })
    end

    defp react(state, {:mcp_started, _action}), do: state
    defp react(state, {:models_discovered, found}), do: Choices.discovered(state, found)
    defp react(state, _reaction), do: state

    # An answer folded through the conversation now, in this process. `:quit`
    # never comes out of an answer, so a `{:stop, _}` here is a state.
    # The TUI shows the live list in a takeover. Other hosts still receive the
    # pure conversation's text response to the same event.
    @doc false
    @spec fold(TUI.t(), term()) :: TUI.t()
    def fold(state, {:mcp_status, _statuses}), do: state
    def fold(state, {:mcp_result, _action, _result}), do: state

    def fold(state, event) do
      {conversation, effects} = Conversation.event(state.conversation, event)

      case run(%{state | conversation: conversation}, effects) do
        {:noreply, state} -> state
        {:stop, state} -> state
      end
    end

    @doc false
    @spec answer(TUI.t(), term()) :: TUI.t()
    def answer(state, message), do: Dispatch.answer(state, host(state), message)

    # Streamed text extends the answer being written: the fragments are arbitrary,
    # and one row each would be unreadable. A fragment's own newlines are the model's
    # though — the paragraphs of the answer — so concatenating through them would
    # turn a whole reply into one line that wraps as a single block.
    defp write(state, text) do
      case String.split(text, "\n") do
        [only] ->
          Transcript.extend(state, only)

        [first | rest] ->
          Enum.reduce(rest, Transcript.extend(state, first), &Transcript.say(&2, :model, &1))
      end
    end

    # A window is a proportion, and a proportion is a picture: the bands are what is
    # in it, drawn to scale. This used to print the status line's numbers stacked
    # vertically, which told a person nothing the footer had not. The footer kept
    # the two numbers that are true at a glance and gave up the per-request split,
    # which lives here now.
    defp context_rows(state) do
      context = state.conversation.context

      case Context.composition(context, transcript_entries(state)) do
        [] ->
          [{:lmx, "context unmeasured · nothing sent yet, or the last thing was a compaction"}]

        segments ->
          [
            {:lmx, "Context window · #{Context.describe(context)}"},
            Art.progress(100 * (1 - free_fraction(segments)), "context"),
            {:context_bar, Enum.map(segments, &{&1.key, &1.fraction})},
            {:context_key, Enum.map(segments, &{&1.key, legend_label(&1)})},
            {:lmx, last_request(context)},
            {:lmx, session_total(state.conversation)}
          ]
      end
    end

    defp free_fraction(segments),
      do:
        Enum.find_value(segments, 0.0, fn segment ->
          if segment.key == :free, do: segment.fraction
        end)

    defp legend_label(%{label: label, tokens: tokens}),
      do: "#{label} #{Context.abbreviate(tokens)}"

    # The three sent bands are one measured number divided by byte share, so
    # the split the provider actually billed — uncached against cache read
    # against cache write — is a different cut of the same tokens and has to
    # be its own line rather than another band.
    defp last_request(%{current: current}) do
      "last request · #{Context.abbreviate(current.input)} uncached in · " <>
        "#{Context.abbreviate(current.cached)} cache read · " <>
        "#{Context.abbreviate(current.cache_write)} cache write · " <>
        "#{Context.abbreviate(current.output)} out"
    end

    defp session_total(%Conversation{context: context} = conversation) do
      delegated = Context.delegated_tokens(context)

      [
        "session · #{Context.abbreviate(Context.cumulative(context))} tok",
        if(delegated > 0, do: "#{Context.abbreviate(delegated)} delegated"),
        requests(Map.get(context.spent, :requests, 0)),
        Conversation.cost(conversation)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
    end

    defp requests(1), do: "1 request"
    defp requests(count), do: "#{count} requests"

    # A snapshot rather than the struct's own rows: the bands are shares of
    # the bytes the last request carried, and only the transcript knows what
    # those were. A host with no session yet gets the collapsed single band,
    # which is what `Lemieux.Context.composition/2` returns without entries.
    defp transcript_entries(%TUI{session: session}) when is_pid(session),
      do: Session.snapshot(session).entries

    defp transcript_entries(_state), do: []

    defp reflecting(:opportunities),
      do: "Mining opportunities from the transcript; they become feedback, never assets."

    defp reflecting(_assessment), do: "Reflecting on the transcript; recommendations only."

    defp skill_help(skill), do: {"/" <> skill.name, skill.description}

    defp columns(rows), do: rows |> Columns.format() |> Enum.join("\n")

    # The screen's own keys, from the table `Lemieux.TUI.Keys` reads — the
    # configured one, so a remapped key is listed where it now is — followed
    # by what the editor and the prompt do that no table maps.
    @editing [
      {"shift-enter", "new line (where the terminal can tell it from enter)"},
      {"@path", "attach a file to the message (tab completes)"},
      {"!command", "run a shell command and share its output"}
    ]

    defp key_help(module) when is_atom(module) and not is_nil(module),
      do: "Keys\nthis screen's keys are mapped by #{inspect(module)}"

    defp key_help(keys) do
      table = Keys.to_map(keys || Keys.default())

      bound =
        table
        |> Enum.group_by(fn {_key, action} -> action end, fn {key, _action} -> key end)
        |> Enum.sort_by(fn {action, _keys} -> action_rank(action) end)
        |> Enum.map(fn {action, keys} ->
          labels = keys |> Enum.map(&HelpCommand.key_label/1) |> Enum.uniq() |> Enum.sort()
          {Enum.join(labels, ", "), action_words(action)}
        end)

      "Keys\n" <> columns(bound ++ @editing)
    end

    defp action_rank(action) do
      Enum.find_index(Keys.names(), &(&1 == action)) || length(Keys.names())
    end

    @action_words %{
      "interrupt" => "cancel the turn · twice to quit",
      "submit" => "send",
      "previous" => "previous menu item or history entry",
      "next" => "next menu item or history entry",
      "scroll_up" => "scroll the transcript up",
      "scroll_down" => "scroll the transcript down",
      "page_up" => "scroll the transcript a page up",
      "page_down" => "scroll the transcript a page down",
      "cycle_mode" => "cycle permission modes (on with --permission-mode ask)",
      "complete" => "complete · queue a message while the agent works",
      "select_queued" => "pick a queued message",
      "revise_queued" => "edit the picked queued message",
      "unstage_queued" => "drop the picked queued message",
      "dismiss" => "clear the input, menus and notices"
    }

    defp action_words(action),
      do: Map.get_lazy(@action_words, action, fn -> String.replace(action, "_", " ") end)

    # `/resume`'s list: this directory's sessions first, most recently active
    # first, because the session a person in this repository is looking for is
    # almost always one they had here. `all` is every directory's. The
    # sessions are the host's index (`state.resume.sessions`), read for
    # `:cwd` and `:updated_at` when it carries them; an index that does not
    # know directories lists everything, newest first, rather than nothing.
    @listed 15

    defp resumable(state, scope) do
      sessions = Enum.reject(state.resume.sessions, &(Map.get(&1, :id) == state.id))
      cwd = state.references.cwd
      known? = Enum.any?(sessions, &is_binary(Map.get(&1, :cwd)))
      {here, elsewhere} = Enum.split_with(sessions, &(known? and Map.get(&1, :cwd) == cwd))

      case {scope, known?, sessions, here} do
        {_scope, _known, [], _here} ->
          "no stored sessions yet"

        {:here, true, _sessions, []} ->
          "no stored sessions in this directory · /resume all lists " <>
            "#{length(elsewhere)} from other directories"

        {:here, true, _sessions, here} ->
          listing("sessions in this directory", here, length(elsewhere))

        {_all_or_unknown, _known, sessions, _here} ->
          listing("stored sessions", sessions, 0)
      end
    end

    defp listing(title, sessions, elsewhere) do
      now = DateTime.utc_now()
      shown = sessions |> Enum.sort_by(&recency/1, {:desc, DateTime}) |> Enum.take(@listed)
      more = length(sessions) - length(shown)

      rows = Enum.map(shown, &("  " <> session_row(&1, now)))

      footer =
        [
          if(more > 0, do: "  … and #{more} more"),
          "/resume SESSION continues one (tab completes)" <>
            if(elsewhere > 0,
              do: " · /resume all adds #{elsewhere} from other directories",
              else: ""
            )
        ]
        |> Enum.reject(&is_nil/1)

      Enum.join(["#{title}, most recent first" | rows] ++ footer, "\n")
    end

    @epoch ~U[1970-01-01 00:00:00Z]

    defp recency(session),
      do: timestamp(Map.get(session, :updated_at)) || timestamp(Map.get(session, :at)) || @epoch

    defp timestamp(%DateTime{} = at), do: at
    defp timestamp(_other), do: nil

    defp session_row(session, now) do
      [
        Map.get(session, :shorthand) || Map.get(session, :id),
        ago(recency(session), now),
        Map.get(session, :model),
        quoted(Map.get(session, :preview))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")
    end

    defp ago(@epoch, _now), do: nil

    defp ago(at, now) do
      seconds = max(DateTime.diff(now, at), 0)

      cond do
        seconds < 60 -> "just now"
        seconds < 3_600 -> "#{div(seconds, 60)}m ago"
        seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
        seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d ago"
        true -> Calendar.strftime(at, "%Y-%m-%d")
      end
    end

    defp quoted(preview) when is_binary(preview) and preview != "" do
      text = preview |> String.replace(~r/\s+/, " ") |> String.trim()
      text = if String.length(text) > 60, do: String.slice(text, 0, 59) <> "…", else: text
      "\"#{text}\""
    end

    defp quoted(_preview), do: nil
  end
end
