defmodule Lemieux.CLI.TUI do
  @moduledoc """
  The default, full agent-harness `lmx` experience.

  The screen uses the shared conversation mechanics and discovers the
  workspace persona, instructions, memory, Agent Skills, legacy commands, and explicitly selected
  plugins before starting a session, and applies them through
  `Lemieux.Extensions.Workspace` — the same callback any extension goes
  through, which is what keeps the screen from having a door into the
  library that an embedder's code lacks. The one-shot runner remains a small
  example of a host-defined Lemieux experience.

  This module is the part that can be reached from anywhere; `Lemieux.TUI` is
  the part that only exists when `ex_ratatui` does. The split lets an embedder
  omit the optional native dependency while the standalone release host always
  includes it. `available/0` verifies that the NIF's `priv` directory is real,
  which catches an incomplete package before `dlopen` produces a stack trace.
  """

  alias Lemieux.CLI
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Ollama
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.SessionIndex
  alias Lemieux.CLI.State
  alias Lemieux.CLI.UpdateCheck
  alias Lemieux.Conversation
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.ID.Shorthand
  alias Lemieux.ModelSpec
  alias Lemieux.Terminal

  @source_url "https://github.com/houllette/lemieux"

  @doc """
  Runs the terminal UI, returning `:ok` or `{:error, exit_status}`.

  Options are `Lemieux.CLI.Options`', and everything else is passed to
  `Lemieux.CLI.Runtime.prepare/2`.
  """
  @spec main(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def main(argv, opts \\ []) do
    with {:ok, options} <- Options.parse(argv, command: :tui),
         :ok <- no_stray_words(options.argv, argv, opts),
         :ok <- prompt(options),
         :ok <- one_of_continue_or_resume(options),
         {:ok, options, opts} <- ExtensionExperience.prepare(options, opts),
         :ok <- model_spec(options, opts),
         :ok <- available(),
         {:ok, permissions} <- Runtime.permissions(options, opts) do
      start(Runtime.project_mcp(options, opts), Keyword.put(opts, :permissions, permissions))
    else
      {:error, :usage, message} -> fail(message, 2)
      {:error, message} -> fail(message)
    end
  end

  # `lmx run`'s check (`Lemieux.CLI.Run`), before a screen opens: a model
  # specification `req_llm` cannot resolve — `--model gpt-4o`, with no
  # provider — used to open an ordinary-looking screen whose first prompt
  # answered "gpt-4o is not a model specification … /retry", advice that
  # could not help. The same sentence and status as `lmx run` instead. Not
  # for a host route, whose model names are its own, nor for `ixway:`
  # names, which are the gateway's, nor where a transcript decides the
  # model (`--resume`, `--continue`).
  defp model_spec(options, opts) do
    if host_route?(options, opts) or options.resume != nil or options.host.continue or
         ModelSpec.provider(options.model) == "ixway" do
      :ok
    else
      case ReqLLM.model(options.model) do
        {:ok, _model} ->
          :ok

        {:error, reason} ->
          {:error, :usage,
           Errors.describe({:unknown_model, options.model, reason}, program: CLI.program(opts))}
      end
    end
  end

  # `--prompt ""` is `--prompt` with nothing to send, which the parser
  # already refuses when the value is missing altogether; a screen that
  # opened and sent nothing would be the silent version of that mistake.
  defp prompt(%Options{given: given}) do
    case Keyword.fetch(given, :prompt) do
      {:ok, text} ->
        if String.trim(text) == "",
          do: {:error, "--prompt is empty; give it the text to send, or leave it out"},
          else: :ok

      :error ->
        :ok
    end
  end

  # The terminal UI takes options and nothing else, and it used to drop
  # anything else without a word: `mix lmx.tui run "Summarize…"` opened an
  # idle screen and lost both the command and the prompt. A word left over is
  # a command typed where the terminal UI was opened instead, or a prompt;
  # each gets the line that would have done it.
  defp no_stray_words([], _argv, _opts), do: :ok

  defp no_stray_words([word | _rest] = words, argv, opts),
    do: {:error, "unexpected argument #{inspect(word)}" <> stray(words, argv, opts)}

  defp stray([word | _rest] = words, argv, opts) do
    if word != "tui" and word in CLI.commands(),
      do: ": the terminal UI takes no command; did you mean `#{CLI.program(opts)} #{word} …`?",
      else: stray_prompt(words, argv, opts)
  end

  # The `run` line that answers the prompt is the whole command line again,
  # flags included, each argument quoted for a POSIX shell, so it can be
  # pasted as it reads. Elixir's quoting, which this used, leaves `$` and
  # backticks for the shell to expand, and the prompt it showed was cut to
  # fit, so pasting it ran a shorter prompt; a line too long to repeat is
  # named instead. `--mouse` is the terminal UI's alone, and `lmx run`
  # would refuse it; `-C DIR` was taken off the line before this saw it.
  #
  # The `--prompt` line is the words as one argument. Only when the words
  # were all there was: with flags among them, which words were values is
  # the parser's to know, and the line is named by its shape instead.
  defp stray_prompt(words, argv, opts) do
    program = CLI.program(opts)
    args = Enum.reject(argv, &(&1 in ~w(--mouse --no-mouse)))
    dir = if opts[:cwd], do: ["-C", opts[:cwd]], else: []
    line = Enum.map_join(dir ++ args, " ", &CLI.shell_quoted/1)

    command =
      if String.length(line) <= 60,
        do: "#{program} run #{line}",
        else: "#{program} run [options] PROMPT"

    prompt = Enum.map_join(dir ++ ["--prompt", Enum.join(words, " ")], " ", &CLI.shell_quoted/1)

    opening =
      if words == argv and String.length(prompt) <= 60,
        do: "#{program} #{prompt}",
        else: "#{program} [options] --prompt PROMPT"

    ": the terminal UI takes a prompt only through --prompt: #{opening}; " <>
      "or answer it without the terminal UI: #{command}"
  end

  defp one_of_continue_or_resume(%Options{host: %{continue: true}, resume: resume})
       when is_binary(resume),
       do: {:error, "use --continue or --resume, not both"}

  defp one_of_continue_or_resume(_options), do: :ok

  @doc """
  Whether the terminal UI can run here, and a sentence when it cannot.
  """
  @spec available() :: :ok | {:error, String.t()}
  def available do
    if Code.ensure_loaded?(Lemieux.TUI) do
      available(:code.priv_dir(:ex_ratatui))
    else
      {:error, not_compiled()}
    end
  end

  @doc """
  Whether the native library could be loaded out of `priv_dir`.

  Takes the directory rather than looking it up so that the answer for a
  packaging this machine is not currently using can still be tested.
  """
  @spec available(priv_dir :: charlist() | binary() | {:error, term()}) ::
          :ok | {:error, String.t()}
  def available({:error, _reason}), do: {:error, not_compiled()}

  def available(priv_dir) do
    if File.dir?(priv_dir), do: :ok, else: {:error, unreachable_native()}
  end

  # Mount only the runtime before opening the screen. Workspace discovery,
  # provider discovery, and session metadata can all do I/O, so the app's
  # supervised startup task supplies the resolved harness after the first frame.
  defp start(options, opts) do
    updates =
      case Keyword.get(opts, :updates) do
        factory when is_function(factory, 1) -> factory.(options)
        host -> host
      end

    opts = Keyword.put(opts, :updates, updates)
    opts = Keyword.put(opts, :interactive?, true)
    # A person answers approvals and `ask_user` questions here, and a person
    # who stepped away for coffee should come back to the question, not to a
    # refusal the session recorded while they were gone.
    opts = Keyword.put_new(opts, :approval_timeout, :infinity)
    # Mounted here, by the process that outlives the screen, rather than left to the
    # app's own `start` callback. A runtime whose parent is the app process tears its
    # sessions down when the app quits — asynchronously, racing the halt that follows
    # — so `session_end` hooks ran or did not depending on timing.
    {:ok, supervisor} = Runtime.mount(opts)
    tasks = Lemieux.Supervisor.task_supervisor(supervisor)
    opts = Keyword.put(opts, :updates, updates || UpdateCheck.host(tasks, opts))

    app =
      opening_app(options, opts,
        # Arity 2, so a screen whose first start failed — no key, a model
        # nobody serves — can start again in place after `/model X` or
        # `/provider X` instead of asking the person to rerun lmx.
        start_async: fn app, overrides ->
          with {:ok, options} <- restart_options(options, overrides, opts),
               do: prepare_start(options, opts, app, tasks)
        end,
        task_supervisor: tasks,
        size: size(),
        title: title()
      )

    # This module is optional in library hosts. Resolve it only after
    # `available/0` has checked the native dependency.
    tui = Module.concat([Lemieux, TUI])
    _ = crash_dump(options.host.state_dir)

    screen =
      quiet_stderr(fn ->
        with {:ok, pid} <- start_screen(tui, app, CLI.program(opts)) do
          announce_update(pid, options)
          discover_models(pid, options, opts)
          {:left, leaving_on_sigterm(pid, fn -> await(pid) end)}
        end
      end)

    case screen do
      {:left, outcome} ->
        Runtime.stop_sessions(supervisor)
        farewell(outcome, options, opts)

      {:error, message} ->
        fail(message)
    end
  end

  # The handler `Lemieux.CLI.Logs` adds when `LMX_LOG_LEVEL` is set.
  @stderr_handler :lmx_stderr

  @doc """
  Runs `fun` with `lmx`'s standard-error log handler muted while standard
  error is the terminal, and gives the handler its level back afterwards,
  however `fun` ends.

  `LMX_LOG_LEVEL` also prints log lines on standard error
  (`Lemieux.CLI.Logs`), and while the screen is up a standard error that is
  the terminal is the screen: every line drew over the frame. So for as long
  as the screen owns the terminal they go to the log file alone, which
  records them as it always does. Standard error redirected when lmx was
  started (`LMX_LOG_LEVEL=debug lmx 2> lmx-debug.log`) draws nothing over
  the frame and keeps them, as `lmx run` does.

  `terminal?` is whether standard error is a terminal: a character device
  (`/dev/null` is one too, and shows nothing either way), rather than a file
  or a pipe; taken to be one where there is no `/dev/stderr` to ask
  (Windows), since muting a redirected one there loses only lines the log
  file records too, and not muting a terminal draws them over the frame.
  `lmx help environment` says so. Public, and `terminal?` an argument, so
  a test can choose either way without a terminal.
  """
  @spec quiet_stderr(fun :: (-> result), terminal? :: boolean()) :: result when result: term()
  def quiet_stderr(fun, terminal? \\ stderr_terminal?())

  def quiet_stderr(fun, false = _redirected) when is_function(fun, 0), do: fun.()

  def quiet_stderr(fun, true = _terminal) when is_function(fun, 0) do
    case :logger.get_handler_config(@stderr_handler) do
      {:ok, %{level: level}} ->
        :ok = :logger.update_handler_config(@stderr_handler, :level, :none)

        try do
          fun.()
        after
          _ = :logger.update_handler_config(@stderr_handler, :level, level)
        end

      {:error, _no_handler} ->
        fun.()
    end
  end

  defp stderr_terminal? do
    case File.stat("/dev/stderr") do
      {:ok, %File.Stat{type: type}} -> type == :device
      {:error, _unknown} -> true
    end
  end

  @doc """
  Everything `lmx` opens the screen with, before there is a session:
  `app_options/3` over `runtime` — the starter, the task supervisor, the
  measured size and the title writer — with the opening harness, and the
  host's own fields beside them. Preparation replaces the harness with the
  session's once that is ready.

  `--prompt TEXT` is passed here as `:prompt`, and only here: the screen
  stages it before there is a session, so it shows as the first queued
  message while the session starts, and sends it once the session is up and
  its opening questions — provider setup, the repository's MCP servers —
  are answered (`Lemieux.TUI.History.hold/2`). With `--resume` or `-c` that
  makes it the resumed session's next message.

  The opening harness is empty but for the palette the person chose:
  `:theme` and `:themes` from `opts`, else `"theme"` and `"themes"` from the
  config file, the same precedence `Lemieux.CLI.Runtime` gives them on the
  session's harness. A screen that opens with no theme asks the terminal
  what its background is, before taking it over, to choose between `dark`
  and `light` (`Lemieux.TUI.Background`): an OSC 11 query with a deadline of
  half a second, a second over SSH, whose answer is typed into the input box
  if it arrives after that. A chosen theme overrides the answer anyway, and
  this host used to open every screen with an empty harness, so it asked on
  every start with a configured theme, and drew the first frames in the
  guessed palette before switching to the chosen one when the session was
  ready. Opened with the chosen theme, the screen asks nothing and is drawn
  in that theme from its first frame. Passing `background: :unknown` instead
  would also have skipped the question, but drawn those first frames dark,
  on a light terminal whose owner had configured `light`.

  Public for the reason `app_options/3` is: opening a real screen needs a
  terminal, and the list this returns is what `start/2` hands the screen, so
  a test of it is a test of what the screen opens with — where a test that
  assembled the list for itself would still pass with `start/2` back on an
  empty harness.
  """
  @spec opening_app(options :: Options.t(), opts :: keyword(), runtime :: keyword()) ::
          keyword()
  def opening_app(%Options{} = options, opts, runtime) when is_list(opts) and is_list(runtime) do
    options
    |> app_options(opts, Keyword.put(runtime, :harness, opening_harness(options, opts)))
    |> Keyword.merge(host_fields(options, opts))
    |> Keyword.put(:prompt, options.given[:prompt])
  end

  defp opening_harness(options, opts) do
    Harness.new(
      theme: Keyword.get_lazy(opts, :theme, fn -> Config.get(options.config, "theme") end),
      themes: Keyword.get_lazy(opts, :themes, fn -> Config.get(options.config, "themes", %{}) end)
    )
  end

  @doc """
  `Lemieux.CLI.crash_dump/2`, for the state directory the terminal UI runs
  with.

  `lmx`'s entry points set the crash dump for every command before any of
  them runs (`Lemieux.CLI.configure/0`), so in `lmx` this finds it set and
  leaves it alone. It stays for a host that opens the terminal UI through
  `main/2` without that setup, before the screen opens.
  """
  @spec crash_dump(state_dir :: Path.t() | nil, current :: String.t() | nil) :: Path.t() | nil
  def crash_dump(state_dir, current \\ System.get_env("ERL_CRASH_DUMP")),
    do: CLI.crash_dump(state_dir, current)

  # After a clean exit, where the conversation went: the screen used the
  # alternate buffer, so leaving it wiped the transcript from view and said
  # nothing about how to get back to it.
  defp farewell(:ok, options, opts) do
    store = Runtime.store(options, opts)

    case resume_hint(store, Keyword.get(opts, :cwd), opts) do
      nil -> :ok
      hint -> IO.puts(:stderr, "lmx: " <> hint)
    end

    :ok
  end

  defp farewell(outcome, _options, _opts), do: outcome

  @doc """
  The line printed when the terminal UI closes: the session `-c` would
  resume in `cwd` and the command that resumes it, or `nil` when there is
  nothing to resume.

  `-c` resumes `Lemieux.CLI.SessionIndex.latest/2`, so the hint names exactly
  the session that flag would pick, spelled with the command this lmx was
  started as (`Lemieux.CLI.program/1`) — `mix lmx -c` from a source
  checkout — and with `-C DIR` when this one worked somewhere other than
  where it was started.

  The directory it was started in can be gone by the time the screen
  closes — the agent's own commands can remove it — which costs the hint
  when no `-C` named another, and never the clean exit.
  """
  @spec resume_hint(store :: Lemieux.Store.t(), cwd :: Path.t() | nil, opts :: keyword()) ::
          String.t() | nil
  def resume_hint(store, cwd, opts) do
    here =
      case File.cwd() do
        {:ok, here} -> here
        {:error, _gone} -> nil
      end

    case cwd || here do
      nil -> nil
      cwd -> resume_hint(store, cwd, here, opts)
    end
  end

  defp resume_hint(store, cwd, here, opts) do
    case SessionIndex.latest(store, cwd) do
      nil ->
        nil

      id ->
        directory =
          if here && Path.expand(cwd) == Path.expand(here),
            do: "",
            else: " -C #{CLI.shell_quoted(cwd)}"

        "session #{Shorthand.of(id)} is saved · `#{CLI.program(opts)}#{directory} -c` resumes it"
    end
  end

  # Once per launch rather than per session start, so a start that failed
  # and ran again does not say it twice; through the message the screen
  # already takes for version news, so it lands in the notice box.
  defp announce_update(pid, options) do
    case update_notice(options.host.state_dir, Lemieux.version()) do
      nil -> :ok
      notice -> send(pid, {:version_notice, notice})
    end
  end

  @doc """
  What to say when `version` is newer than the one the terminal UI last
  started with in `state_dir`, or `nil`; records `version` either way (see
  `Lemieux.CLI.State.record_version/2`).

  The link is the changelog as released with `version`, at its tag, rather
  than the one on `main`, whose first section is whatever has changed since.
  """
  @spec update_notice(state_dir :: Path.t() | nil, version :: String.t()) :: String.t() | nil
  def update_notice(state_dir, version) do
    case State.record_version(state_dir, version) do
      {:updated, _previous} ->
        "Lemieux was updated to v#{version} since you last used it · " <>
          "[full changelog](#{@source_url}/blob/v#{version}/CHANGELOG.md)"

      :unchanged ->
        nil
    end
  end

  @doc """
  Starts `screen` with the `app` options, or says in a sentence why it could not.

  The screen's server is linked to the caller, and when it cannot claim a
  terminal — `lmx` started from a pipe, a CI job, another agent's shell — it
  stops inside `init/1`. That stop used to arrive here as an exit signal and
  kill this process before `start_link` returned, so the `{:error, reason}`
  answer was never read; in the release it took the boot down with it and
  left an `erl_crash.dump` (2026-09-19: `{:terminal_init_failed, "Device not
  configured (os error 6)"}`). Exits are trapped only for the length of the
  call, so a screen that crashes later still takes this process with it, as
  before.

  Public for the reason `app_options/3` is: the failure it exists for cannot
  be produced by opening a real screen in a test. `program` is how the
  sentence spells the command to use instead (`Lemieux.CLI.program/1`).
  """
  @spec start_screen(screen :: module(), app :: keyword(), program :: String.t()) ::
          {:ok, pid()} | {:error, String.t()}
  def start_screen(screen, app, program \\ "lmx")
      when is_atom(screen) and is_list(app) and is_binary(program) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      case screen.start_link(app) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, reason} ->
          # The server's exit, if the start did not already consume it. Left
          # in the mailbox it would be a message nobody reads for the rest of
          # the sitting.
          receive do
            {:EXIT, _pid, ^reason} -> :ok
          after
            0 -> :ok
          end

          {:error, screen_failure(reason, program)}
      end
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp screen_failure({:terminal_init_failed, detail}, program) do
    """
    the terminal UI needs an interactive terminal, and could not claim one \
    (#{terminal_detail(detail)}).

    Run #{program} in a terminal window, or use `#{program} run PROMPT` from \
    scripts, pipes and CI.\
    """
  end

  defp screen_failure(reason, _program), do: Conversation.describe(reason)

  defp terminal_detail(detail) when is_binary(detail), do: detail
  defp terminal_detail(detail), do: inspect(detail)

  defp prepare_start(options, opts, app, tasks) do
    store = Runtime.store(options, opts)
    list_sessions = fn -> SessionIndex.recent(store) end
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    {options, continued} = continue(options, store, cwd)
    opts = Keyword.update(opts, :notices, continued, &(&1 ++ continued))
    options = resolve_model(options, opts)

    # The recent-session picker reads up to fifty transcripts. It needs no
    # workspace or provider state, so overlap that disk work with harness
    # preparation instead of making "Starting session..." wait for both in
    # sequence. The result is still checked before the session becomes ready.
    history = Task.Supervisor.async_nolink(tasks, list_sessions)
    # The configured Ixway route checks its instance and model catalogue over
    # HTTP. Start those requests before local workspace assembly so their
    # latency overlaps the work needed for every session.
    provider_task =
      Task.Supervisor.async_nolink(tasks, fn ->
        provider = Keyword.get_lazy(opts, :provider, fn -> Runtime.tui_provider(options) end)

        if String.starts_with?(options.model, "ixway:") do
          Runtime.discover_tui_provider(provider)
        else
          {:ok, provider}
        end
      end)

    try do
      with {:ok, discovered} <- workspace(options, opts),
           opts = Keyword.put(opts, :workspace, discovered),
           {:ok, standard_tools} <- Runtime.standard_tools(options, opts),
           {:ok, provider} <- Task.await(provider_task, :infinity),
           {:ok, prepared} <- Runtime.prepare(options, Keyword.put(opts, :provider, provider)),
           {:ok, sessions} <- Task.await(history, :infinity),
           {:ok, session} <- started(Runtime.start(prepared, subscriber: subscribers(app, opts))) do
        Models.remember(options, prepared.model)
        options = %{options | model: prepared.model}
        first_run = first_run(options, opts)

        # The resolved harness is what determines skills, notices, status, and
        # the commands for both the session and the screen.
        ready =
          app_options(options, opts,
            harness: prepared.harness,
            sessions: sessions,
            list_sessions: list_sessions,
            resume_session: resume_session(options, opts, prepared),
            new_session: new_session(options, opts, prepared),
            standard_tools: standard_tools,
            first_run: first_run,
            permissions: prepared.permissions,
            sandbox: prepared.sandbox,
            mcp_trust: prepared.mcp_trust,
            checkpoints: prepared.checkpoints,
            environment: prepared.harness.environment
          )
          |> Keyword.merge(Keyword.drop(host_fields(options, opts), [:permissions]))

        {:ok, session, ready}
      end
    after
      Task.shutdown(history, :brutal_kill)
      Task.shutdown(provider_task, :brutal_kill)
    end
  end

  defp resume_session(options, opts, prepared) do
    fn id, subscriber ->
      resumed = Runtime.resume_options(options, id)

      resume_opts =
        opts
        |> Keyword.delete(:tools)
        |> Keyword.delete(:reasoning_effort)
        |> Keyword.put(:provider, prepared.options[:provider])
        |> Keyword.put(:subscriber, subscribers(subscriber, opts))

      resumed |> Runtime.start_session(resume_opts) |> started()
    end
  end

  defp new_session(options, opts, prepared) do
    fn subscriber ->
      new_opts =
        opts
        |> Keyword.put(:provider, prepared.options[:provider])
        |> Keyword.put(:subscriber, subscribers(subscriber, opts))

      %{options | resume: nil} |> Runtime.start_session(new_opts) |> started()
    end
  end

  # A transcript another `lmx` holds is refused by the session with the
  # holder's details; the screen gets the sentence saying whose it is.
  defp started({:ok, session}), do: {:ok, session}

  defp started({:error, {:session_locked, _holder} = reason}),
    do: {:error, Errors.describe(reason)}

  defp started(error), do: error

  # `--continue` resumes the newest session that ran in this directory, or
  # opens a new one saying so.
  defp continue(%Options{host: %{continue: true}, resume: nil} = options, store, cwd) do
    case SessionIndex.latest(store, cwd) do
      nil -> {options, ["No earlier session ran in #{cwd}; this is a new one."]}
      id -> {%{options | resume: id}, []}
    end
  end

  defp continue(options, _store, _cwd), do: {options, []}

  # A model nobody chose follows `Lemieux.CLI.Models`, including a model the
  # local Ollama daemon serves when no provider has a key. A host that
  # supplied its own provider keeps the model it asked for.
  defp resolve_model(options, opts) do
    if Keyword.has_key?(opts, :provider),
      do: options,
      else: options |> Models.resolve(opts) |> Models.local(opts)
  end

  # The panel is what says a key is missing: a startup notice saying it too
  # put two different instructions on the first screen. `opts` goes along so
  # its credential checks and its second look at Ollama answer to the same
  # `:env` and `:ollama` the start model was resolved with.
  defp first_run(options, opts) do
    if host_route?(options, opts), do: nil, else: Models.first_run(options, opts)
  end

  defp host_route?(options, opts),
    do: Keyword.has_key?(opts, :provider) or options.ixway != nil or options.base_url != nil

  defp request_cap(options), do: options |> Options.limits() |> Keyword.get(:max_requests)

  # What the screen reads beside the harness, every key present even when it
  # has nothing to say: an absent `:permissions` and a `nil` one mean the
  # same thing — permissions are off — and the screen says so.
  defp host_fields(options, opts) do
    [
      permissions: Keyword.get(opts, :permissions),
      request_cap: request_cap(options),
      config_path: Config.path(options.config),
      history_file: options.host.state_dir && Path.join(options.host.state_dir, "history.jsonl"),
      notifications: Config.get(options.config, "notifications", true),
      discover: rediscovery(options, opts)
    ]
  end

  # How `/provider ollama` looks again when the look `discover_models/3`
  # took as the screen opened found nothing: the same look
  # (`Lemieux.Conversation.Command.Provider`). Without it, somebody who
  # started Ollama after `lmx` — what the keyless line tells them to do —
  # was told "ollama has no available models" until they restarted. A host
  # that supplied its own provider looks for nothing.
  defp rediscovery(options, opts) do
    if Keyword.has_key?(opts, :provider) and not Keyword.has_key?(opts, :discover_models),
      do: %{},
      else: %{"ollama" => discovery(options, opts)}
  end

  @doc """
  What the screen starts on again after a failed start, once the person has
  typed `/model X` or `/provider X` (`overrides`, from
  `Lemieux.TUI.Lifecycle.restart/2`): `options` as if they had typed the
  model on the command line, or the sentence that says why there is none.

  `/provider NAME` starts on the model the config file names for `NAME`
  (`Lemieux.CLI.Config.preferred_models/1`), else on `NAME`'s row of
  `Lemieux.CLI.Models.recommended/0`; `NAME` is trimmed and lower-cased
  first, as a running screen does (`Lemieux.Conversation.Command.Provider`).
  Ollama has no row there, because which model depends on what the daemon
  serves, so `/provider ollama` asks the daemon and starts on the model a
  first start without a key would (`Lemieux.CLI.Models.local/2`):
  `Lemieux.CLI.Ollama.local_model/2`'s pick, a model that can call tools,
  the most recently used, then the most recently pulled — the model
  `/provider ollama` switches to on a running screen too
  (`discovered_models/2`). Without that it found no model, started again on
  the one that had just failed, and said it was starting with Ollama. A
  daemon that does not answer, or serves nothing that can call tools, fails
  the start again with what to do about it. It asks under `--config none`
  as well: the person named the provider, which is not the guess a hermetic
  run declines to make.

  Another provider with neither a configured nor a recommended model keeps
  the model it had, as it always has. `opts[:ollama]` answers for the
  daemon, as in `discovered_models/2`.
  """
  @spec restart_options(options :: Options.t(), overrides :: keyword(), opts :: keyword()) ::
          {:ok, Options.t()} | {:error, String.t()}
  def restart_options(%Options{} = options, overrides, opts)
      when is_list(overrides) and is_list(opts) do
    case {Keyword.get(overrides, :model), Keyword.get(overrides, :provider)} do
      {model, _provider} when is_binary(model) ->
        {:ok, chosen(options, model)}

      {nil, provider} when is_binary(provider) ->
        provider_options(options, provider |> String.trim() |> String.downcase(), opts)

      _nothing ->
        {:ok, options}
    end
  end

  defp provider_options(options, provider, opts) do
    case {provider_model(options, provider), provider} do
      {nil, "ollama"} -> local_options(options, opts)
      {model, _provider} -> {:ok, chosen(options, model)}
    end
  end

  # The daemon is asked as `default_discovery/2` asks it, whatever Ixway
  # route is configured: the screen runs that route beside the direct
  # providers (`Lemieux.CLI.Runtime.tui_provider/1`), so the model chosen is
  # reached directly, as `/model ollama:NAME` after a failed start is.
  defp local_options(options, opts) do
    case Ollama.local_model(%{options | ixway: nil}, ollama_opts(options, opts)) do
      {:ok, %{model: model}} ->
        {:ok, chosen(options, model)}

      {:error, :unreachable} ->
        {:error, "Ollama did not answer; start it, then /provider ollama tries again"}

      {:error, :none} ->
        {:error,
         "Ollama is running, but none of its models can call tools; pull one that can " <>
           "(ollama pull NAME; ollama.com/search?c=tools lists them), then " <>
           "/provider ollama tries again"}
    end
  end

  defp chosen(options, nil), do: options

  defp chosen(options, model) do
    options = %{options | model: model, given: Keyword.put(options.given, :model, model)}
    put_in(options.host.model_source, :flag)
  end

  defp provider_model(options, provider) do
    Config.preferred_models(options.config)[provider] ||
      Enum.find_value(Models.recommended(), &(&1.provider == provider && &1.model))
  end

  @doc """
  Everything the screen is started with, from the parsed options and the host.

  A function rather than a literal at the call site, and public rather than
  private, because nothing could observe that list: `--mouse` had no way to
  reach the app for exactly this reason, and a key that silently stops being
  forwarded looks from the outside like a feature that was never built. A
  test asserts the mapping here; opening a real screen needs a terminal.

  `runtime` carries the assembled `Lemieux.Harness` under `:harness`, the
  session starter, the measured size, the title writer, and the resume
  callback. Startup replaces the temporary harness after preparation finishes.
  Everything else comes from the parsed command line or from the embedding
  host's `opts`.

  ## Why the harness travels whole

  The harness is forwarded under `:harness`, not copied out field by field:
  `Lemieux.TUI.new/1` reads the theme, the palettes, the key map, the
  renderers, the slash commands, the status line, the processing words, the
  follow-up hint, the skills and the notices from it wherever the individual
  option is absent. The screen and the session it shows are shaped by one
  list — the extensions that shaped the first session also decided which
  skills it offers, what the workspace scan noticed and whose status line it
  draws — and a copy per field here was the place the two drifted apart:
  every field the harness grew had to be added to this list by hand, and one
  that was not reached the session and never the screen, with nothing to say
  so. The harness is required, not optional, for the same reason: a screen
  opened without one would draw the shipped defaults over a session shaped by
  something else.
  """
  @spec app_options(options :: Options.t(), opts :: keyword(), runtime :: keyword()) :: keyword()
  def app_options(%Options{} = options, opts, runtime) when is_list(opts) and is_list(runtime) do
    %Harness{} = Keyword.fetch!(runtime, :harness)

    runtime ++
      [
        welcome: Keyword.get(opts, :welcome),
        updates: Keyword.get(opts, :updates),
        command_policy: Keyword.get(opts, :command_policy),
        # The CLI captures by default for wheel scrolling, link clicks and
        # drag selection; --no-mouse returns selection to the terminal.
        mouse_capture: options.host.mouse,
        mcp_config: options.mcp_config,
        # The feedback ledger sits beside the sessions directory, so the flag
        # that moved one moves the other.
        sessions_dir: options.sessions_dir,
        preferred_models:
          Keyword.get(
            opts,
            :preferred_models,
            Config.preferred_models(options.config)
          ),
        preferred_efforts:
          Keyword.get(opts, :preferred_efforts, Config.preferred_efforts(options.config)),
        feedback_store: Keyword.get(opts, :feedback_store),
        feedback_dir: Keyword.get(opts, :feedback_dir)
      ]
  end

  # Discovered once, here, and handed to every session this screen starts
  # (`Lemieux.CLI.Runtime.discover_workspace/2`).
  defp workspace(options, opts) do
    case Keyword.get(opts, :workspace) do
      %Discovery{} = workspace -> {:ok, workspace}
      _missing -> Runtime.discover_workspace(options, opts)
    end
  end

  defp subscribers(tui, opts) do
    opts
    |> Keyword.get(:subscriber)
    |> List.wrap()
    |> then(&Enum.uniq([tui | &1]))
  end

  # Discovery is a host concern and a network effect, so it starts only after
  # the screen and session exist and runs under the runtime's Task.Supervisor.
  # The TUI opens immediately when Ollama is slow or absent; a successful list
  # arrives as an ordinary message and redraws completion in place.
  defp discover_models(tui, options, opts) do
    discover = discovery(options, opts)

    supervisor =
      opts
      |> Keyword.get(:supervisor, Lemieux.Supervisor)
      |> Lemieux.Supervisor.task_supervisor()

    Task.Supervisor.start_child(supervisor, fn ->
      send(tui, {:models_discovered, discover.()})
    end)

    :ok
  end

  defp discovery(options, opts) do
    case Keyword.fetch(opts, :discover_models) do
      {:ok, fun} when is_function(fun, 0) -> fun
      :error -> default_discovery(options, opts)
    end
  end

  defp default_discovery(options, opts) do
    if Keyword.has_key?(opts, :provider),
      do: fn -> [] end,
      else: fn -> discovered_models(%{options | ixway: nil}, opts) end
  end

  @doc """
  What the screen is told Ollama serves, once it has asked: the models
  `/model` offers beside the session's own, in the order `/provider ollama`
  takes them.

  That is `Lemieux.CLI.Ollama.models/2`'s list without the local tags whose
  capabilities lack `tools`, led by `{:preferred, spec}` for
  `Lemieux.CLI.Ollama.local_model/2`'s pick — the model `lmx` would start on
  by itself: one that can call tools, the most recently used, then the most
  recently pulled. `/provider ollama` switches to the first local model found
  when nothing the person chose is among them
  (`Lemieux.Conversation.Command.Provider`), and found alphabetically, that
  was whichever tag sorted first, a model without tools included.

  A tag without tools is not offered at all, rather than offered and never
  switched to. The session's tools go with every request and Ollama refuses
  such a request for a model without them, which is why the session's own
  list leaves out catalog models without tools
  (`Lemieux.Session.available_models/2`); and the screen is told names and
  an order, not capabilities, so it could not tell the two kinds apart. A tag
  the daemon listed no capabilities for is still offered, since `/api/tags`
  alone cannot rule it out; the pick is the one model `/api/show` confirms.

  The daemon's `/api/tags` is asked once, and its answer is what the list
  and the pick are made from (`:served`, `Lemieux.CLI.Ollama`); each used
  to ask again, three requests for one list.

  `opts[:ollama]` takes what `Lemieux.CLI.Models.local/2` passes on —
  `:get`, `:post` and `:recent` — and `:api_key` for Ollama Cloud; tests
  answer for the daemon with them.
  """
  @spec discovered_models(options :: Options.t(), opts :: keyword()) ::
          [String.t() | {:preferred, String.t()}]
  def discovered_models(%Options{} = options, opts) do
    ollama = ollama_opts(options, opts)
    served = Ollama.served(options, ollama)
    ollama = Keyword.put(ollama, :served, served)
    offered = Ollama.models(options, ollama)

    case served do
      {:ok, tags} ->
        without_tools =
          for %{model: model, capabilities: [_ | _] = known} <- tags,
              "tools" not in known,
              do: model

        offered
        |> Enum.reject(&(&1 in without_tools))
        |> led_by(Ollama.local_model(options, ollama))

      :unreachable ->
        offered
    end
  end

  defp led_by(offered, {:ok, %{model: model}}),
    do: [{:preferred, model} | List.delete(offered, model)]

  defp led_by(offered, {:error, _none}), do: offered

  # What `Lemieux.CLI.Ollama` is asked with: the host's `:ollama`, and the
  # models `lmx` used most recently to rank its pick, as a first start ranks
  # it (`Lemieux.CLI.Models.local/2`).
  defp ollama_opts(options, opts) do
    opts
    |> Keyword.get(:ollama, [])
    |> Keyword.put_new_lazy(:recent, fn -> State.recent_models(options.host.state_dir) end)
  end

  # Supplied here rather than defaulted inside the app, for the reason the size is
  # measured here: writing an escape sequence is an effect on a stream, and the app
  # is a library module a host may have embedded somewhere with no business
  # retitling anything. This host owns a local terminal, so it asks.
  #
  # `Lemieux.Terminal` rather than `ExRatatui.set_terminal_title/1`, which writes
  # through the NIF to this process's own stdout — the right terminal only for
  # `:local`, and `lmx` is about to grow other transports. Public for the reason
  # `app_options/3` is: a screen that silently stopped being handed one looks from
  # the outside like a feature nobody built.
  @doc false
  @spec title() :: (String.t() -> :ok | {:error, term()})
  def title, do: &Terminal.title(&1, :local)

  # Asked here rather than inside the app, because this is the process with a
  # terminal attached: `ExRatatui.terminal_size/0` talks to the tty and hangs
  # `mount/1` wherever there is none, which is every test. It matters because a
  # terminal that is never resized never sends a resize event, and until one
  # arrives the paging keys have only the struct's default to go on.
  defp size do
    ratatui = Module.concat(["ExRatatui"])
    size(&controlling_terminal?/0, &ratatui.terminal_size/0)
  end

  @doc """
  The terminal's size from `measure`, asked only when `terminal?` says there
  is a terminal to ask; `nil` otherwise, or when the measurement fails.

  Without a terminal, crossterm measures by running `tput` and waiting for
  it. This VM leaves SIGCHLD ignored, so the kernel reaps `tput` itself: the
  wait fails with "No child processes", or, begun before `tput` has exited,
  blocks until every child of the VM has exited, which `erl_child_setup`
  never does. `lmx` started from a pipe hung there, silently, on about two
  launches in five (2026-09-29), instead of saying it needs a terminal.
  crossterm asks `/dev/tty` first, and the screen cannot start without it
  either, so where it will not open there is nothing to measure.

  Public for the reason `start_screen/2` is: the hang cannot be produced on
  demand in a test.
  """
  @spec size(terminal? :: (-> boolean()), measure :: (-> term())) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def size(terminal?, measure) when is_function(terminal?, 0) and is_function(measure, 0) do
    with true <- terminal?.(),
         {width, height} when is_integer(width) and is_integer(height) <- measure.() do
      {width, height}
    else
      _unmeasured -> nil
    end
  end

  # Opening `/dev/tty` answers at once either way: it opens where this
  # process has a controlling terminal and fails with ENXIO where it has none.
  defp controlling_terminal? do
    case :file.open(~c"/dev/tty", [:read, :raw]) do
      {:ok, tty} ->
        :ok = :file.close(tty)
        true

      {:error, _reason} ->
        false
    end
  end

  # The screen was started by this process, outside any application, so on
  # SIGTERM `init:stop/0` reached it last and killed it outright: ExRatatui
  # never restored the terminal, and the shell came back inside the alternate
  # screen with any-motion mouse reporting on and the cursor hidden (`kill
  # PID`, and the TERM the release launcher forwards for HUP, INT and TERM).
  # Leave the UI first, as Ctrl-C twice does, and exit by the ordinary path.
  #
  # Stopped `:normal`, not `:shutdown`. The screen is linked to this process,
  # and a `:shutdown` exit is an exit signal that took this process with it:
  # Elixir's script runner printed `** (EXIT from #PID<…>) shutdown` under
  # the restored screen, `mix lmx` exited 1, and this command's own way out —
  # its sessions stopped, their `session_end` hooks run, the resume hint —
  # never ran. A `:normal` exit is the one `await/1` waits for. In the
  # release it relies on `Lmx.Boot`'s trap stopping the VM with
  # `:init.stop/1`; with `System.stop/1` there, it deadlocked the VM.
  #
  # The trap lasts as long as the screen does: this is a host's command, and
  # a signal trap outliving it would be a decision about somebody else's VM.
  # A trap that has fired stays, though. The VM is stopping by then — Elixir
  # runs SIGTERM's default, `init:stop/0`, after every trap — and removing it
  # is a call to the VM's signal server, which in the release is still busy
  # with `Lmx.Boot`'s grace while the turn in flight reports its
  # cancellation. Waiting for that held this command's exit for three seconds
  # (3.09 s against 0.04 s with the trap left, measured in the release with a
  # turn in flight, 2026-10-04), and removing it from another process instead
  # holds Elixir's configuration server, which the `System.stop/1` in
  # `Lmx.Boot.finish/1` needs, as long.
  #
  # The trap's function is a closure of this module's, held by the signal
  # server while the screen runs and, once it has fired, until the VM stops:
  # a retained local callback in a process the upgrade guard does not
  # inspect, as `Lemieux.TUI.Signals` says of its own. A release that changes
  # this module restarts rather than upgrading hot
  # (`dist/lmx/upgrades/AGENTS.md`).
  defp leaving_on_sigterm(pid, wait) do
    # Shared memory rather than a message: the trap runs in the signal
    # server, and the screen's `:DOWN` and a message from there could arrive
    # in either order; the flag is set before the screen is asked to stop.
    fired = :atomics.new(1, [])

    trap =
      System.trap_signal(:sigterm, fn ->
        :ok = :atomics.put(fired, 1, 1)

        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _gone -> :ok
        end

        :ok
      end)

    try do
      wait.()
    after
      with {:ok, id} <- trap, 0 <- :atomics.get(fired, 1), do: System.untrap_signal(:sigterm, id)
    end
  end

  # The app draws and polls in its own process; this one has nothing to do but
  # wait for it to stop, which is what leaving the UI does.
  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, :shutdown} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> fail("the terminal UI stopped: #{inspect(reason)}")
    end
  end

  # The terminal UI's modules are compiled only where `ex_ratatui` is loaded
  # (`if Code.ensure_loaded?(ExRatatui.App)`), so a copy of lemieux compiled
  # before the dependency was added has none of them until it is compiled
  # again, which for a path dependency takes a forced `deps.compile`.
  defp not_compiled do
    """
    the terminal UI is not built into this copy of lemieux.

    It needs the optional `ex_ratatui` dependency, which is left out by
    default because it is a Rust NIF and not something to impose on a project
    that only wanted the library. Add it:

        {:ex_ratatui, "~> 0.16"}

    then `mix deps.get`. A path dependency on lemieux was compiled without
    it, so compile it again: `mix deps.compile lemieux --force`.

    Embedded hosts can still run sessions without a terminal UI.\
    """
  end

  defp unreachable_native do
    """
    the terminal UI's native library is not in a real `priv` directory.

    Install an official OTP release-built `lmx` binary, or run lmx from a
    source checkout with `mix lmx`.\
    """
  end

  defp fail(message, status \\ 1) do
    IO.puts(:stderr, "lmx: #{message}")

    {:error, status}
  end
end
