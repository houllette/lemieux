# Every path that changes which session a screen shows: mounting, the startup
# task's reply, `/new`, `/resume`, clearing, and leaving.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Lifecycle do
    @moduledoc "Starts, hydrates, switches and stops the session a `Lemieux.TUI` shows."

    alias Lemieux.Conversation
    alias Lemieux.ID.Shorthand
    alias Lemieux.ModelSpec
    alias Lemieux.Session
    alias Lemieux.Tools
    alias Lemieux.TUI
    alias Lemieux.TUI.Appearance
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Colour
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Events
    alias Lemieux.TUI.FirstRun
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.MCPStatus
    alias Lemieux.TUI.Pager
    alias Lemieux.TUI.PlanPanel
    alias Lemieux.TUI.Policy
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.SessionHydration
    alias Lemieux.TUI.Setup
    alias Lemieux.TUI.Signals
    alias Lemieux.TUI.Submission
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.Trust
    alias Lemieux.TUI.Turn
    alias Lemieux.TUI.Updates

    @habs_frame_ms 110
    @habs_frames 10

    @typep reply :: {:noreply, TUI.t()}

    @doc false
    @spec mount(opts :: keyword()) :: {:ok, TUI.t()} | term()
    def mount(opts) do
      opts = opts |> Setup.with_harness() |> Keyword.put_new(:scroll_coalesce?, true)

      # A host with network preparation starts it under its own supervisor.
      # The screen must return its first state before discovering providers or
      # asking a session for its catalog, both of which can make HTTP calls.
      case Keyword.fetch(opts, :start_async) do
        {:ok, start} when is_function(start, 1) or is_function(start, 2) ->
          app = self()
          first = first_start(start)

          task =
            Task.Supervisor.async_nolink(Keyword.fetch!(opts, :task_supervisor), fn ->
              start_async_session(first, app)
            end)

          state =
            opts
            |> Setup.new()
            |> Setup.sized(opts)
            |> equipped(opts)
            |> start_habs()

          {:ok,
           put_in(state.resume, %{
             state.resume
             | initial_task: task,
               startup_status: :loading
           })}

        :error ->
          case mount_started(opts) do
            {:ok, state} -> {:ok, Updates.start(state)}
            error -> error
          end
      end
    end

    # `:infinity`, because nothing here waits on a network: a session answers
    # `snapshot/2` and `info/2` at once even while its MCP servers connect, and
    # this runs in a task the person can Ctrl-C out of. The five-second
    # default used to fail startup behind a slow server that the session
    # itself was only waiting on.
    # A two-argument starter takes the overrides `restart/2` supplies after a
    # failed start (`/model X`, `/provider X`); the first start has none. lmx
    # passes one, and mount matching only the one-argument form crashed every
    # `lmx` launch at mount.
    defp first_start(start) when is_function(start, 2), do: fn app -> start.(app, []) end
    defp first_start(start) when is_function(start, 1), do: start

    defp start_async_session(start, app) do
      with {:ok, session, ready_opts} <- start.(app) do
        snapshot = Session.snapshot(session, :infinity)
        {:ok, session_details(session, snapshot), ready_opts}
      end
    end

    defp mount_started(opts) do
      # Started here rather than handed in, because this process has to be one
      # subscriber and does not exist until the runtime has started it. The
      # callback may include other host subscribers alongside `self()`.
      case Keyword.fetch(opts, :start) do
        {:ok, start} when is_function(start, 0) ->
          with {:ok, session} <- start.(), do: {:ok, mounted(opts, session)}

        :error ->
          {:ok,
           opts
           |> Setup.new()
           |> Setup.sized(opts)
           |> equipped(opts)
           |> Setup.notices(opts[:notices])
           |> Composer.start_cursor_blink()}
      end
    end

    defp mounted(opts, session) do
      snapshot = Session.snapshot(session, :infinity)
      details = session_details(session, snapshot)
      built = opts |> Setup.new() |> Setup.sized(opts) |> equipped(opts)

      built
      |> hydrate(details)
      |> carry_queue(built)
      |> Appearance.retitle()
      |> Setup.welcome(opts[:welcome])
      |> Setup.notices(opts[:notices])
      |> opened()
      |> Composer.start_cursor_blink()
      |> send_staged()
    end

    # A host that started its session before the screen has nothing else
    # that sends what was staged — its `:prompt` — so the screen asks itself
    # to, once it has mounted.
    defp send_staged(%TUI{history: %{queued: []}} = state), do: state

    defp send_staged(state) do
      send(self(), :continue_queued)
      state
    end

    # What this screen learned about its terminal before it took it over, and
    # the traps that put the terminal back if the process is told to stop.
    # Kept in `:terminal`, which a startup that finishes later carries over
    # whole (`started/4`), so it is learned once per screen.
    #
    #   * `:background` — `Lemieux.TUI.Background`'s answer, asked by
    #     `Lemieux.TUI.start_link/1` before the screen owned the terminal.
    #   * `:colours` — `:truecolor`, or `:ansi256` where every RGB colour is
    #     drawn as its nearest palette colour (`Lemieux.TUI.Colour`).
    #   * `:signal_traps` — the SIGTERM trap a host asked for with
    #     `trap_signals: true`, or none; see `Lemieux.TUI.Signals`.
    #
    # Only a local terminal is this process's to read or restore: a remote
    # transport and a headless test screen get only what their host states
    # outright — a background, a colour depth — and never a trap.
    defp equipped(state, opts) do
      local? = local_terminal?(opts)

      terminal =
        state.terminal
        |> Map.put(:background, Keyword.get(opts, :background, :unknown))
        |> Map.put(:colours, Keyword.get_lazy(opts, :colours, fn -> colours(opts, local?) end))
        |> Map.put(:signal_traps, if(Signals.wanted?(opts), do: Signals.trap(self()), else: []))

      Appearance.detected(%{state | terminal: terminal})
    end

    defp local_terminal?(opts),
      do:
        Keyword.get(opts, :transport, :local) == :local and
          not Keyword.has_key?(opts, :test_mode)

    defp colours(opts, true = _local?),
      do: opts |> Keyword.get_lazy(:env, &System.get_env/0) |> Colour.depth()

    defp colours(_opts, false = _local?), do: :truecolor

    # The startup task answered with a session: the screen becomes that session's.
    @doc false
    @spec started(TUI.t(), reference(), map(), keyword()) :: reply()
    def started(state, ref, details, ready_opts) do
      Process.demonitor(ref, [:flush])

      # Preparation can finish after a resize, version notice, or local-model
      # discovery. Keep those while installing the resolved harness and session.
      previous_lines = state.lines
      opts = Setup.with_harness(ready_opts)

      ready =
        opts
        |> Setup.new()
        |> then(
          &%{
            &1
            | input: state.input,
              terminal: state.terminal,
              modal: state.modal
          }
        )
        |> put_in([Access.key!(:resume), :start_async], state.resume.start_async)
        |> put_in([Access.key!(:resume), :task_supervisor], state.resume.task_supervisor)
        |> put_in([Access.key!(:catalog), :discovered], state.catalog.discovered)
        # The resolved harness may name a theme the first state did not
        # have, for a host that opens the screen with an empty harness and
        # lets the session's configuration or extensions choose one. `lmx`
        # opens with the configured theme already
        # (`Lemieux.CLI.TUI.opening_app/3`), so for it this matters only
        # when an extension chose another. With none, the background
        # decides again, from what the terminal said at start.
        |> Appearance.detected()
        |> hydrate(details)
        |> carry_queue(state)
        |> Appearance.retitle()
        |> Setup.welcome(opts[:welcome])
        |> Setup.notices(opts[:notices])

      ready =
        %{
          ready
          | lines: previous_lines ++ ready.lines,
            resume: %{ready.resume | startup_status: :ready}
        }
        |> opened()
        |> Composer.start_cursor_blink()
        |> Updates.start()

      # What was staged while the session was starting — the host's
      # `:prompt`, and what was typed and queued — goes now, unless an
      # opening question holds it (`Lemieux.TUI.History.hold/2`).
      Submission.continue_queued(ready)
    end

    # The queue staged before there was a session, which hydrating drops.
    # See `Lemieux.TUI.History.carry_queue/2`.
    defp carry_queue(state, from),
      do: %{state | history: History.carry_queue(state.history, from.history)}

    # The first things a new sitting says and asks: what runs without asking
    # and where, then whether the repository's MCP servers may start, then —
    # for somebody with no credentials — which provider to use.
    defp opened(state) do
      state
      |> Policy.banner()
      |> Trust.check()
      |> FirstRun.open()
    end

    @doc """
    Tries starting again after a failed start, with `overrides` — `model:`
    or `provider:` — when the host's starter accepts them.

    A starter of one argument cannot be told what changed, so the screen
    says how to restart instead: a retry with the same inputs would fail
    the same way.
    """
    @spec restart(TUI.t(), keyword()) :: TUI.t()
    def restart(
          %TUI{resume: %{start_async: start, task_supervisor: supervisor}} = state,
          overrides
        )
        when is_function(start, 2) and not is_nil(supervisor) do
      app = self()

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          start_async_session(fn app -> start.(app, overrides) end, app)
        end)

      :ok = ExRatatui.textarea_set_value(state.input, "")

      state
      |> put_in([Access.key!(:resume), :initial_task], task)
      |> put_in([Access.key!(:resume), :startup_status], :loading)
      |> Transcript.say(:lmx, "starting again with #{describe_overrides(overrides)}")
    end

    def restart(state, overrides) do
      Transcript.say(
        state,
        :lmx,
        "this host cannot start again from here · run lmx with #{flags(overrides)}"
      )
    end

    defp describe_overrides(overrides),
      do: Enum.map_join(overrides, ", ", fn {key, value} -> "#{key} #{value}" end)

    defp flags(overrides),
      do: Enum.map_join(overrides, " ", fn {key, value} -> "--#{key} #{value}" end)

    @doc """
    A key while the session is starting or failed to start.

    Everything edits the input box as usual, so a person can type ahead.
    Enter queues what was typed to be sent when the session is up; after a
    failure it takes the three commands that still mean something without a
    session — `/model`, `/provider` and `/quit`.
    """
    @spec starting_key(ExRatatui.Event.Key.t(), TUI.t()) :: reply() | {:stop, TUI.t()}
    def starting_key(event, state) do
      case Keys.action(state.status.keys, event) do
        :interrupt -> Composer.interrupt(state)
        :submit -> starting_submit(state, String.trim(Composer.typed_value(state)))
        _other -> Composer.key(event, state)
      end
    end

    defp starting_submit(state, quit) when quit in ["/quit", "/exit"], do: stopping(state)

    defp starting_submit(%TUI{resume: %{startup_status: :failed}} = state, "/model " <> model),
      do: {:noreply, restart(state, model: String.trim(model))}

    defp starting_submit(
           %TUI{resume: %{startup_status: :failed}} = state,
           "/provider " <> provider
         ),
         do: {:noreply, restart(state, provider: String.trim(provider))}

    defp starting_submit(%TUI{resume: %{startup_status: :failed}} = state, _typed),
      do:
        {:noreply,
         Flash.show(
           state,
           "no session · /model NAME or /provider NAME tries again · /quit leaves"
         )}

    defp starting_submit(state, ""), do: {:noreply, state}

    defp starting_submit(state, _typed) do
      {:noreply, queued} = History.queue_draft(state)
      {:noreply, Flash.show(queued, "queued · it is sent when the session is up")}
    end

    # Watching the session the screen shows, so a session that dies is a row
    # saying so and not an exit the next keystroke runs into.
    defp monitor(%TUI{session: session} = state) do
      if state.resume.monitor, do: Process.demonitor(state.resume.monitor, [:flush])

      ref = if is_pid(session), do: Process.monitor(session)
      put_in(state.resume, %{state.resume | monitor: ref, down: nil})
    end

    @doc """
    The session the screen shows exited. Its transcript is still on disk, so
    the row offers the one thing that brings it back: Enter on an empty line
    resumes it.

    A steer still drawn as waiting went with the session, so it is marked
    undelivered: left waiting, its box went on offering `/unsteer`, which
    then called a session that was not there.
    """
    @spec session_down(TUI.t(), term()) :: TUI.t()
    def session_down(state, reason) do
      state
      |> put_in([Access.key!(:resume), :monitor], nil)
      |> put_in([Access.key!(:resume), :down], reason)
      |> Submission.mark_steers(:not_sent)
      |> Turn.stop_processing()
      |> put_in([Access.key!(:conversation), Access.key!(:busy?)], false)
      |> Transcript.say(
        :notice,
        "the session stopped (#{Conversation.describe(reason)}); press Enter on an empty line to resume it, or /new"
      )
    end

    @doc false
    @spec start_failed(TUI.t(), reference(), term()) :: reply()
    def start_failed(state, ref, reason) do
      Process.demonitor(ref, [:flush])
      {:noreply, startup_failed(state, reason)}
    end

    @doc false
    @spec startup_failed(TUI.t(), term()) :: TUI.t()
    def startup_failed(state, reason) do
      state
      |> put_in([Access.key!(:resume), :initial_task], nil)
      |> put_in([Access.key!(:resume), :startup_status], :failed)
      |> Map.put(:overlay, nil)
      |> Transcript.say(:notice, "could not start session: #{describe(reason)}")
    end

    # A session another process holds is refused rather than opened twice;
    # which process, and where, is what a person needs to find it.
    @doc false
    @spec describe(term()) :: String.t()
    def describe({:session_locked, %{} = holder}) do
      where = [
        holder[:process] || "another lmx",
        holder[:os_pid] && "pid #{holder[:os_pid]}",
        holder[:host] && "on #{holder[:host]}"
      ]

      "that session is open in #{where |> Enum.reject(&(&1 in [nil, false])) |> Enum.join(" ")}" <>
        if(holder[:since], do: " since #{holder[:since]}", else: "") <>
        "; close it there first, or /new for a fresh one"
    end

    def describe({:error, reason}), do: describe(reason)
    def describe(reason), do: Conversation.describe(reason)

    # Starts the Go Habs Go animation, for startup and `/habs`.
    @doc false
    @spec start_habs(TUI.t()) :: TUI.t()
    def start_habs(state) do
      token = make_ref()
      Process.send_after(self(), {:habs_tick, token}, @habs_frame_ms)

      %{state | overlay: %{frame: 0, tick: token}}
    end

    @doc false
    @spec habs_tick(TUI.t(), reference()) :: reply()
    def habs_tick(
          %TUI{resume: %{startup_status: :loading}, overlay: %{tick: token, frame: frame}} = state,
          token
        ) do
      # Keep the visible frames cycling until preparation answers. The final
      # blank frame belongs to the one-shot command's exit, not this loop.
      Process.send_after(self(), {:habs_tick, token}, @habs_frame_ms)
      {:noreply, put_in(state.overlay.frame, rem(frame + 1, @habs_frames - 1))}
    end

    def habs_tick(%TUI{overlay: %{tick: token, frame: frame}} = state, token)
        when frame < @habs_frames - 1 do
      Process.send_after(self(), {:habs_tick, token}, @habs_frame_ms)

      {:noreply, put_in(state.overlay.frame, frame + 1)}
    end

    def habs_tick(%TUI{overlay: %{tick: token}} = state, token),
      do: {:noreply, %{state | overlay: nil}}

    def habs_tick(state, _token), do: {:noreply, state}

    # `/new`: starts a fresh session off the render loop.
    @doc false
    @spec new_session(TUI.t()) :: TUI.t()
    def new_session(%TUI{resume: %{busy?: true}} = state),
      do: Transcript.say(state, :lmx, "already switching sessions")

    def new_session(%TUI{resume: %{new: nil}} = state),
      do: Transcript.say(state, :lmx, "new sessions are not available in this host")

    def new_session(state) do
      app = self()
      %{new: start, list: list, sessions: sessions} = state.resume

      Task.start(fn ->
        send(app, {:new_result, start_new(start, list, app, sessions)})
      end)

      put_in(state.resume.busy?, true)
    end

    # `/resume ID`: resumes a recorded session off the render loop.
    @doc false
    @spec resume_session(TUI.t(), String.t()) :: TUI.t()
    def resume_session(%TUI{resume: %{busy?: true}} = state, _id),
      do: Transcript.say(state, :lmx, "already resuming a session")

    def resume_session(%TUI{resume: %{start: nil}} = state, _id),
      do: Transcript.say(state, :lmx, "session resume is not available in this host")

    def resume_session(state, id) do
      app = self()
      %{start: start, list: list, sessions: sessions} = state.resume

      Task.start(fn ->
        send(app, {:resume_result, id, resumed(start, list, id, app, sessions)})
      end)

      put_in(state.resume.busy?, true)
    end

    # A `/new` or `/resume` landed: the screen now shows that session. `verb`
    # is what the row says, `"resumed"`, or `nil` for `/new`, which says
    # nothing.
    @doc false
    @spec switched(TUI.t(), map(), list(), String.t() | nil) :: TUI.t()
    def switched(state, details, sessions, verb) do
      previous = state.session

      if is_pid(previous) and previous != details.session do
        stop_previous(state, previous)
      end

      switched =
        state
        |> put_in([Access.key!(:resume), :sessions], sessions)
        |> hydrate(details)
        |> still_unchosen(state.conversation, verb)
        # A `/name` belonged to the session that was open, so it goes with it.
        |> put_in([Access.key!(:appearance), :name], nil)
        |> Appearance.retitle()
        |> Updates.start()

      if verb,
        do: Transcript.say(switched, :lmx, "#{verb} #{Shorthand.of(switched.id)}"),
        else: switched
    end

    # `/new` starts on the startup model ("the startup configuration",
    # `docs/cli.md`), and when that is a placeholder nobody chose
    # (`Conversation.unchosen/1`), the new session is still nobody's choice.
    # Hydration builds a new conversation, which counts its model as chosen,
    # so the first prompt's missing-key line named the placeholder's vendor
    # again after `/new`. Carried to the placeholder only: a session started
    # on another model is the host's choice. A `/resume` runs on the model
    # its transcript recorded and names that vendor, as `lmx --resume` does.
    #
    # Two ways to know it is the placeholder. The session that was open was
    # on it, still unchosen. Or the host's first-run setup still says nobody
    # chose and no provider has a key — what `Lemieux.TUI.Policy` marks the
    # first session by — and names this model: a keyless start, Esc, then
    # `/provider ollama` leaves the open session chosen, and `/new` returns
    # to the placeholder. The setup goes once the panel switches the session
    # (`Lemieux.TUI.FirstRun.saved/3`), so a key pasted there, which the
    # line should not deny, ends this.
    defp still_unchosen(%TUI{conversation: conversation} = state, previous, nil = _new) do
      if same_unchosen?(previous, conversation.model) or startup_placeholder?(state),
        do: %{state | conversation: Conversation.unchosen(conversation)},
        else: state
    end

    defp still_unchosen(state, _previous, _resumed), do: state

    defp same_unchosen?(%Conversation{model: model, model_chosen?: false}, model), do: true
    defp same_unchosen?(_previous, _model), do: false

    defp startup_placeholder?(%TUI{
           conversation: %Conversation{model: model},
           session_view: %{first_run: %{model: model, providers: rows} = setup}
         })
         when is_list(rows),
         do:
           setup[:selected] == nil and
             not Enum.any?(rows, &(Map.get(&1, :credential) == :present))

    defp startup_placeholder?(_state), do: false

    # The session the screen stopped showing. Off the render loop, because a
    # session's stop runs its `session_end` hooks; under the screen's task
    # supervisor, so the work is owned by something that outlives a frame
    # and goes with the screen, and linked to the screen where a host gave
    # it no supervisor. A session that is already gone — it died, or its
    # runtime took it down first — has had the stop it was going to get, so
    # that exit ends the task quietly: it used to crash an unlinked task,
    # which logged an error on every test run that switched sessions.
    defp stop_previous(%TUI{resume: %{task_supervisor: supervisor}}, session)
         when not is_nil(supervisor) do
      {:ok, _task} = Task.Supervisor.start_child(supervisor, fn -> stop_session(session) end)
      :ok
    end

    defp stop_previous(_state, session) do
      {:ok, _task} = Task.start_link(fn -> stop_session(session) end)
      :ok
    end

    defp stop_session(session) do
      GenServer.stop(session, :normal)
    catch
      :exit, _gone -> :ok
    end

    @doc false
    @spec resume_failed(TUI.t(), term()) :: TUI.t()
    def resume_failed(state, reason) do
      state = put_in(state.resume.busy?, false)

      Transcript.say(state, :lmx, "could not resume: #{describe(reason)}")
    end

    @doc false
    @spec new_failed(TUI.t(), term()) :: TUI.t()
    def new_failed(state, reason) do
      state = put_in(state.resume.busy?, false)

      Transcript.say(state, :lmx, "could not start a new session: #{describe(reason)}")
    end

    defp resumed(resume_session, list_sessions, id, subscriber, current_sessions) do
      with {:ok, session} <- resume_session.(id, subscriber) do
        details = session |> Session.snapshot(:infinity) |> then(&session_details(session, &1))
        sessions = refreshed_sessions(list_sessions, current_sessions)
        {:ok, details, sessions}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, reason}
    end

    defp start_new(start, list_sessions, subscriber, current_sessions) do
      with {:ok, session} <- start.(subscriber) do
        details = session |> Session.snapshot(:infinity) |> then(&session_details(session, &1))
        sessions = refreshed_sessions(list_sessions, current_sessions)
        {:ok, details, sessions}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, reason}
    end

    defp refreshed_sessions(nil, sessions), do: sessions

    defp refreshed_sessions(list_sessions, sessions) do
      case list_sessions.() do
        {:ok, refreshed} -> refreshed
        {:error, _reason} -> sessions
      end
    end

    defp session_details(session, snapshot) do
      provider = Map.get(snapshot, :provider) || ModelSpec.provider(snapshot.model)
      info = info(session)

      %{
        session: session,
        snapshot: snapshot,
        info: info,
        providers: Session.available_providers(session),
        models: Choices.models_for(session, provider),
        model_metadata: Session.model_metadata(session),
        efforts: Session.reasoning_efforts(session),
        tool_statuses: tool_statuses(session, info),
        mcp: mcp_statuses(session, info),
        # Asked once, because a host profile is fixed for the life of a
        # session — `Lemieux.Tool.Profile` is explicit that it is authority
        # granted at start, not state that drifts.
        elixir: Session.tool_decision(session, Tools.Eval)
      }
    end

    # `info/2` answers at once; `tool_status/1` and `mcp_status/2` wait until
    # startup MCP connections settle, which behind a slow server is longer
    # than any startup should. So while they are still connecting the local
    # tools stand in for the catalog, and `Lemieux.TUI.MCPStatus` asks again
    # once `{:ready, _}` arrives.
    defp info(session), do: Session.info(session, :infinity)

    defp tool_statuses(_session, %{ready?: false, tools: names}),
      do: Enum.map(names, &%{name: &1, source: :local, enabled?: true})

    defp tool_statuses(session, _info), do: Session.tool_status(session)

    defp mcp_statuses(_session, %{mcp: statuses}) when is_list(statuses), do: statuses

    # Fills a state from a session's details: transcript, catalog, turn, open questions.
    @doc false
    @spec hydrate(TUI.t(), map()) :: TUI.t()
    def hydrate(state, details) do
      state =
        state
        |> SessionHydration.hydrate(details, %{
          view: %{
            width: Screen.columns(state),
            theme: Screen.theme(state),
            renderers: Screen.renderers(state)
          },
          empty_tools: Setup.no_tools(Setup.jev_reset(state.tools.jev)),
          idle_turn: Turn.idle_turn(),
          history_limit: History.limit()
        })
        |> Choices.put_tool_statuses(details.tool_statuses)
        |> put_in([Access.key!(:tool_choices), :elixir], details.elixir)
        |> session_view(details)
        |> MCPStatus.watch()
        |> monitor()

      state =
        if state.conversation.busy?,
          do: Turn.start_processing(state),
          else: Turn.stop_processing(state)

      state =
        case state.conversation.question do
          %{ask_user: true} = question -> Events.open_question_flow(state, question)
          _other -> state
        end

      restore_approval_cards(state, state.conversation.approvals)
    end

    # What the session has already said about itself: its MCP servers and
    # request count (from `info/2`, when it answered), its plan, and the full
    # output of its last tool calls for the pager.
    defp session_view(state, details) do
      info = Map.get(details, :info)

      state =
        state
        |> put_in([Access.key!(:session_view), :plan], nil)
        |> put_in([Access.key!(:session_view), :outputs], [])
        |> put_in([Access.key!(:session_view), :noticed], [])
        |> put_in([Access.key!(:session_view), :requests], (info && info.requests) || 0)
        |> put_in(
          [Access.key!(:session_view), :request_cap],
          state.session_view.request_cap || (info && info.max_requests)
        )
        |> MCPStatus.start(details.mcp, (info && info.ready?) != false)
        |> PlanPanel.restore(details.snapshot.entries)

      details.snapshot.entries
      |> Enum.filter(&match?(%{type: :tool_result}, &1))
      |> Enum.take(-20)
      |> Enum.reduce(state, fn %{payload: payload}, state ->
        Pager.remember(
          state,
          payload["call_id"] || "tool",
          payload["name"] || "tool",
          output_text(payload["output"])
        )
      end)
    end

    defp output_text(text) when is_binary(text), do: text
    defp output_text(nil), do: ""
    defp output_text(other), do: inspect(other, limit: 50, printable_limit: 20_000)

    # A call still parked when this screen attached gets its card and the
    # live row's phase, exactly as a live one does, so a person who arrives
    # late can answer it. After the turn is started, because starting one
    # resets the phase.
    defp restore_approval_cards(state, approvals) do
      Enum.reduce(approvals, state, fn approval, state ->
        state
        |> Events.present_approval(%{
          id: approval.call_id,
          name: approval.name,
          arguments: approval.arguments
        })
        |> approval_phase(approval.name)
      end)
    end

    defp approval_phase(%TUI{turn: %{started_at: started}} = state, name)
         when is_integer(started),
         do: Events.phase(state, :approval, %{name: name})

    defp approval_phase(state, _name), do: state

    # A host clear event keeps the history's entries: up-arrow is a record of what
    # this person typed, which clearing the agent's context is no reason to forget.
    # Where they were *looking* in it does reset, along with the selection, because
    # the rows both referred to are gone.
    @doc false
    @spec cleared(TUI.t()) :: TUI.t()
    def cleared(state) do
      %{
        state
        | lines: [],
          tools: Setup.no_tools(state.tools.jev),
          history: History.browsing(state.history, nil),
          selection: nil,
          turn: Turn.idle_turn(),
          scroll: 0
      }
    end

    # Every way out of the screen, so the tab stops claiming to be a session
    # that ended. An empty title rather than a remembered one: what was there
    # before this process started is the shell's business, and it puts its own
    # back on the next prompt.
    @doc false
    @spec stopping(TUI.t()) :: {:stop, TUI.t()}
    def stopping(state) do
      state.terminal.title.("")

      {:stop, state}
    end

    @doc """
    The VM was told to stop, and the SIGTERM trap a host asked for
    (`trap_signals: true`) asked the screen to leave first, so the terminal
    is restored by the same `terminate/2` a Ctrl-C exit runs. See
    `Lemieux.TUI.Signals`, which also says why the trap is released from a
    process of its own rather than here.
    """
    @spec signalled(state :: TUI.t(), signal :: :sigterm) :: {:stop, TUI.t()}
    def signalled(state, _signal), do: stopping(state)

    @doc false
    @spec terminate(term(), TUI.t()) :: :ok
    def terminate(_reason, %TUI{resume: %{initial_task: %Task{} = task}} = state) do
      release_traps(state)
      Task.shutdown(task, :brutal_kill)
      :ok
    end

    def terminate(_reason, state) do
      release_traps(state)
      Updates.stop(state)
    end

    # Never waited for: see `Lemieux.TUI.Signals.release/1`.
    defp release_traps(%TUI{terminal: %{signal_traps: traps}}) when is_list(traps),
      do: Signals.release(traps)

    defp release_traps(_state), do: :ok
  end
end
