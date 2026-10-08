defmodule Lemieux.Tools.Bash do
  @moduledoc """
  Runs a shell command and returns what it said.

  This is the tool that makes four tools enough. Searching, listing, running
  tests, git, moving files, installing things — all of it is already a program
  on the machine, and a shell is how a model reaches them without lemieux
  growing a tool per verb.

  ## A non-zero exit is a result

  `run/2` returns `{:ok, output}` for a command that failed, with the status
  named in the output. The model asked what happens when you run the tests; a
  failing test suite is the answer, not a malfunction. Returning `{:error, _}`
  would tell the loop that the *tool* broke, which is a different thing and
  leads somewhere else. `{:error, _}` is reserved for "the command could not
  be run at all".

  Every ending is stated: an exit status, a timeout, an output cap, or a
  transport that broke before the command finished. A command whose output
  stops without explanation is one the model will read as complete.

  Collected results retain typed `structured_content`: `status` is `exited`
  with an integer `exit_status`, `timed_out` with `timeout_ms`, or
  `output_limit` with `max_output_bytes`. Foreground streams end with a
  structured success item, and configured runners return a `Tool.Result`.
  `Tool.collect/2` preserves the text-only interface. These facts distinguish
  a failed verifier from a failed tool invocation without changing either's
  outcome or adding provider-visible metadata.

  The last of those is stated *as* a transport failure rather than folded into
  an exit status. A dead pipe reported as `[exit status 1]` looks exactly like
  a command that genuinely failed, so the model reads it as an answer and goes
  on to debug the command — which is the wrong machine entirely.

  ## Background commands

  `background: true` hands a command to `Lemieux.Background` and returns its
  id immediately. A later call with `task_id` polls it; adding `wait_ms` waits
  for a terminal state without cancelling the command when that wait expires,
  and `cancel: true` stops it. The command is supervised outside the
  initiating tool task but monitors the session which owns it, so ending the
  session still ends its processes.

  Cancelling is the model's to ask for because nothing else will. A dev server
  started to check one page runs until the session ends or its hour is up, and
  a model that had no way to stop it either left it holding the port the next
  attempt needed or reached for `kill` with a pid it had to guess.

  ## Inside the call's deadline

  The session stops any one tool call at its deadline, `deadline_ms` in the
  context: this tool's ten minutes under the host's `:tool_timeout_ms`. A
  call stopped there ends as an error that says nothing about the command,
  so a `timeout_ms` or `wait_ms` that would outlast it is cut to end shortly
  before it, and the result says the cut was this session's limit. A
  benchmark host with a three-minute limit (#38) saw a `wait_ms: 180000`
  poll of a running task come back as a failed call, under a schema that
  allowed 600000; the model fell back to one-minute polls, 42 of them. Cut,
  the same poll answers "still running", as a shorter wait would, and a
  foreground command that runs out of time is reported as timed out, with
  the advice to start it in the background.

  The schema's maxima stay the tool's own and say a session may allow
  less. A schema is the same for every session that uses the tool, and the
  limit is each session's, which the model learns from the first result
  that reaches it.

  ## Nobody is at this terminal

  Every command runs with `PAGER` and `GIT_PAGER` set to `cat`,
  `GIT_TERMINAL_PROMPT=0` and `GIT_EDITOR=true`. A command that stops to ask a
  person something waits out its whole deadline here, and the model then
  reads a timeout, not the question: `git commit` without `-m` opened an editor
  nobody could see. With these set it fails at once ("aborting commit due to
  empty commit message"), which is an answer the model can act on. `CI` is not
  set: it changes what test runners and package managers *do*, not just
  whether they ask.

  Output loses its terminal escape sequences (see `Lemieux.Tool.Escapes`), and
  a `null` or empty `task_id` — which some providers send for every optional
  field the model did not use — counts as absent rather than as a second
  request alongside `command`.

  ## What runs, and with what permissions

  `bash -c` (falling back to `sh`) in the session's working directory, with
  the launching user's full permissions and environment. There is no allowlist
  here and no sandbox. That is a decision, not an omission: a policy layer
  inside the library would be one every host has to work around, and none of
  them agree on what it should say. Hosts attach theirs at
  `before_tool_call` (see `Lemieux.Hooks`) and put the real isolation —
  containers, users, network policy — outside the VM where it can actually
  hold.

  A host whose containment boundary is elsewhere can replace only execution:
  `new(runner: &MyHost.Sandbox.exec/2)` produces a configured bash tool that
  passes the command, working directory and timeout to the host. The tool's
  public name, schema, output sanitation, truncation and exit-status semantics
  remain here rather than being reimplemented by every host.

  ## Killing what it started

  The local environment ties each command to a monitored ExCmd owner and ends
  that owner's OS process group on timeout, which covers the shell and ordinary
  descendants. A process that deliberately detaches into a new session can
  still survive: following it would cross the command's kernel-owned boundary.
  The answer to that edge is the same as above — real containment belongs to
  whatever the session is running inside.
  """

  @behaviour Lemieux.Tool
  @behaviour Lemieux.Tool.Configured

  alias Lemieux.Background
  alias Lemieux.Environment
  alias Lemieux.Tool
  alias Lemieux.Tool.Escapes
  alias Lemieux.Tool.Result

  @max_bytes 30_000
  # Bounds memory rather than context: everything past this is thrown away as
  # it arrives, because a runaway command can produce gigabytes faster than
  # anyone notices.
  @default_timeout 120_000
  @max_timeout 600_000
  @default_background_timeout :timer.hours(1)
  @max_background_timeout :timer.hours(24)
  @max_wait 600_000

  # What a timeout or a wait cut to fit the call's deadline leaves before it,
  # to kill the command and report: see "Inside the call's deadline" above.
  # A tenth of a short deadline, so a test's or a host's one-second limit
  # still leaves the command most of it.
  @deadline_margin 5_000

  # See "Nobody is at this terminal" above.
  @non_interactive [
    {"PAGER", "cat"},
    {"GIT_PAGER", "cat"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_EDITOR", "true"}
  ]

  @typedoc "A host-owned command runner used to relocate execution."
  @type runner ::
          (command :: String.t(), opts :: keyword() ->
             {:ok, output :: String.t(), status :: non_neg_integer()} | {:error, term()})

  @type t :: %__MODULE__{runner: runner()}

  @enforce_keys [:runner]
  defstruct [:runner]

  @doc """
  Builds a bash tool whose commands are executed by the host.

  The runner receives the command plus `:cwd` and `:timeout_ms`. It returns
  captured combined output and the exit status; bash still sanitises and
  truncates that output and reports non-zero exits as ordinary tool results.
  The call itself is bounded by the same timeout as the built-in runner.

  Configured tools contain executable state and are therefore not restored
  from a transcript. A host must pass the configured tool again when resuming.
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{runner: Keyword.fetch!(opts, :runner)}
  end

  @impl Lemieux.Tool
  def name, do: "bash"
  @impl Lemieux.Tool.Configured
  def name(%__MODULE__{}), do: name()

  @impl Lemieux.Tool
  def description do
    """
    Run a shell command in the working directory and return its combined
    stdout and stderr.

    Use this for anything a shell can do: searching, listing files, running
    tests, git. A non-zero exit is reported in the output rather than being an
    error — read it and decide what to do. Long output is truncated in the
    middle, and long-running commands are killed after a timeout.

    Each call starts a fresh shell in the working directory: a cd, an exported
    variable or a shell function does not carry over to the next call, so chain
    dependent steps in one command with &&. Nothing can answer a prompt — pass
    flags such as -m or --yes instead of waiting for one.

    Set background to start a server, a watcher or a long script without
    blocking. The result gives a task_id; call bash with that task_id to poll
    it, add wait_ms to await completion for a bounded time, or set cancel to
    stop it.
    """
  end

  @impl Lemieux.Tool.Configured
  def description(%__MODULE__{}), do: description()

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The shell command to run."},
        "background" => %{
          "type" => "boolean",
          "description" => "Start command in the background and return a task id."
        },
        "task_id" => %{
          "type" => "string",
          "description" =>
            "A background task id to poll, await or cancel instead of starting a command."
        },
        "cancel" => %{
          "type" => "boolean",
          "description" => "With task_id, stop that background task."
        },
        "wait_ms" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => @max_wait,
          "description" =>
            "With task_id, wait this long for completion. Omit or use 0 to poll immediately. " <>
              "A session may allow one call less."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_timeout,
          "description" =>
            "How long to wait before killing it, in milliseconds. " <>
              "Defaults to #{@default_timeout}, maximum #{@max_timeout}; " <>
              "a session may allow one call less."
        },
        "background_timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_background_timeout,
          "description" =>
            "Lifetime of a background command. Defaults to #{@default_background_timeout}, " <>
              "maximum #{@max_background_timeout}."
        }
      },
      # Anthropic rejects top-level schema combinators for custom tools. Both
      # fields stay optional in the advertised object and run/2 enforces
      # exactly one; restoring `anyOf` makes the entire model request fail
      # before bash has a chance to validate the call.
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool.Configured
  def schema(%__MODULE__{}), do: schema()

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "arbitrary", resource_types: ["operating_system"]},
      runtime: %{
        timeout_ms: @max_timeout,
        max_output_bytes: @max_bytes,
        concurrency: %{class: "exclusive"}
      }
    }
  end

  @impl Lemieux.Tool.Configured
  def metadata(%__MODULE__{}), do: metadata()

  @impl Lemieux.Tool
  def run(args, context) when is_map(args), do: dispatch(present(args), context, nil)
  def run(_args, _context), do: {:error, "bash needs a command or background task_id"}

  @impl Lemieux.Tool.Configured
  @spec run(t(), Tool.args(), Tool.context()) ::
          {:ok, String.t() | Result.t()} | {:error, String.t()}
  def run(%__MODULE__{runner: runner}, args, context) when is_map(args),
    do: dispatch(present(args), context, runner)

  def run(%__MODULE__{}, _args, _context),
    do: {:error, "bash needs a command or background task_id"}

  @doc """
  The variables every command is run with so that nothing waits on a person.

  Public so a host runner or an environment that relocates execution can
  apply the same ones.
  """
  @spec non_interactive_env() :: [{String.t(), String.t()}]
  def non_interactive_env, do: @non_interactive

  # A provider that fills every optional field sends `"task_id": null` beside a
  # command, and the model is then told it asked for both. Absent and null are
  # the same request; so is the empty string, which no task is ever called.
  defp present(args) do
    args
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.reject(fn {key, value} -> key == "task_id" and value == "" end)
  end

  # `runner` is nil for the environment's own commands and the host's callback
  # for a configured tool; everything but a foreground command is the same
  # either way.
  defp dispatch(%{"command" => _command, "task_id" => _task_id}, _context, _runner) do
    {:error, "bash accepts a command or a task_id, not both"}
  end

  defp dispatch(%{"task_id" => task_id, "cancel" => true}, context, _runner)
       when is_binary(task_id),
       do: cancel(task_id, context)

  defp dispatch(%{"task_id" => task_id} = args, context, _runner) when is_binary(task_id),
    do: observe(task_id, args, context)

  defp dispatch(%{"command" => command, "background" => true} = args, context, runner)
       when is_binary(command) and command != "",
       do: start_background(command, args, context, runner)

  defp dispatch(%{"command" => command} = args, context, nil)
       when is_binary(command) and command != "" do
    {timeout, cut} = timeout(args, context)

    case Environment.run(Environment.from_context(context), command,
           cwd: context.cwd,
           timeout_ms: timeout,
           env: @non_interactive
         ) do
      {:ok, events} -> {:stream, render_events(events, cut)}
      {:error, reason} -> {:error, "could not run the command: #{describe_start(reason)}"}
    end
  end

  defp dispatch(%{"command" => command} = args, context, runner)
       when is_binary(command) and command != "" do
    {timeout, cut} = timeout(args, context)
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      runner_process(runner, command, [cwd: context.cwd, timeout_ms: timeout], caller, result_ref)

    receive do
      {^result_ref, {:ok, output, status}}
      when is_binary(output) and is_integer(status) and status >= 0 ->
        Process.demonitor(monitor_ref, [:flush])
        note = if status == 0, do: nil, else: "[exit status #{status}]"

        {:ok,
         command_result(render([Escapes.strip(output)], note), %{
           "status" => "exited",
           "exit_status" => status
         })}

      {^result_ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, "could not run the command: #{inspect(reason)}"}

      {^result_ref, {:runner_crashed, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, "the bash runner crashed: #{Exception.format_exit(reason)}"}

      {^result_ref, other} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, "the bash runner returned an invalid result: #{inspect(other)}"}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, "the bash runner crashed: #{Exception.format_exit(reason)}"}
    after
      timeout ->
        Process.exit(pid, :kill)

        {:ok,
         command_result(render([], timed_out(timeout, cut)), %{
           "status" => "timed_out",
           "timeout_ms" => timeout
         })}
    end
  end

  defp dispatch(_args, _context, _runner),
    do: {:error, "bash needs a command or background task_id"}

  # The manager exists to make ownership bidirectional. Merely monitoring a runner
  # reports its crash but lets it outlive a cancelled tool task; the manager
  # monitors its owner and links its worker, so either side going away takes the
  # host callback down without linking runner failures into the session.
  defp runner_process(runner, command, opts, owner, result_ref) do
    spawn_monitor(fn ->
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(owner)
      manager = self()

      worker =
        spawn_link(fn ->
          result = invoke_runner(runner, command, opts)
          send(manager, {:runner_result, result})
        end)

      receive do
        {:runner_result, result} -> send(owner, {result_ref, result})
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, :kill)
        {:EXIT, ^worker, reason} -> send(owner, {result_ref, {:runner_crashed, reason}})
      end
    end)
  end

  defp invoke_runner(runner, command, opts) do
    runner.(command, opts)
  rescue
    error -> {:runner_crashed, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:runner_crashed, {kind, reason}}
  end

  defp timeout(%{"timeout_ms" => ms}, context) when is_integer(ms) and ms > 0,
    do: within_deadline(min(ms, @max_timeout), context)

  defp timeout(_args, context), do: within_deadline(@default_timeout, context)

  # `{ms, cut}`: what the command or wait gets, and whether the deadline is
  # what decided it. A context without one (a host calling the tool itself)
  # keeps what was asked.
  defp within_deadline(ms, %{deadline_ms: deadline}) when is_integer(deadline) and deadline > 0 do
    limit = max(deadline - min(@deadline_margin, div(deadline, 10)), 1)
    if ms > limit, do: {limit, true}, else: {ms, false}
  end

  defp within_deadline(ms, _context), do: {ms, false}

  defp timed_out(timeout, false), do: "[timed out after #{timeout}ms and was killed]"

  defp timed_out(timeout, true),
    do:
      "[timed out after #{timeout}ms and was killed: that is the longest one call may run in " <>
        "this session, so start a longer command with background and poll it]"

  defp background_timeout(%{"background_timeout_ms" => ms})
       when is_integer(ms) and ms > 0,
       do: min(ms, @max_background_timeout)

  defp background_timeout(_args), do: @default_background_timeout

  defp wait(%{"wait_ms" => ms}, context) when is_integer(ms) and ms >= 0,
    do: within_deadline(min(ms, @max_wait), context)

  defp wait(_args, _context), do: {0, false}

  defp start_background(command, args, context, runner) do
    opts = [
      supervisor: context.supervisor,
      session_id: context.session_id,
      owner: context.session,
      command: command,
      cwd: context.cwd,
      environment: Environment.from_context(context),
      timeout_ms: background_timeout(args),
      env: @non_interactive
    ]

    opts = if runner, do: Keyword.put(opts, :runner, runner), else: opts

    case Background.start(opts) do
      {:ok, task_id} ->
        text =
          "Background task #{task_id} started. " <>
            "Call bash with task_id to poll it, or add wait_ms to await completion."

        {:ok,
         Result.new(text,
           structured_content: %{"task_id" => task_id, "status" => "running"}
         )}

      {:error, reason} ->
        {:error, "could not start the background command: #{inspect(reason)}"}
    end
  end

  defp cancel(task_id, context) do
    with :ok <- Background.cancel(context.supervisor, context.session_id, task_id),
         {:ok, snapshot} <- Background.poll(context.supervisor, context.session_id, task_id) do
      {:ok, background_result(snapshot)}
    else
      {:error, :not_found} ->
        {:error, "background task #{inspect(task_id)} was not found for this session"}
    end
  end

  defp observe(task_id, args, context) do
    {wait_ms, cut} = wait(args, context)

    result =
      if wait_ms == 0,
        do: Background.poll(context.supervisor, context.session_id, task_id),
        else: Background.await(context.supervisor, context.session_id, task_id, wait_ms)

    case result do
      {:ok, snapshot} ->
        {:ok, background_result(snapshot)}

      {:error, {:timeout, snapshot}} ->
        {:ok, background_result(snapshot, still_running(task_id, wait_ms, cut))}

      {:error, :not_found} ->
        {:error, "background task #{inspect(task_id)} was not found for this session"}
    end
  end

  defp still_running(task_id, wait_ms, false),
    do: "Background task #{task_id} is still running after waiting #{wait_ms}ms."

  defp still_running(task_id, wait_ms, true),
    do:
      "Background task #{task_id} is still running after waiting #{wait_ms}ms, the longest " <>
        "one call may wait in this session. Call again to keep waiting."

  defp background_result(snapshot, prefix \\ nil) do
    status = background_status(snapshot)
    output = Escapes.strip(snapshot.output)
    output = if output == "", do: "[no output yet]", else: output

    text =
      [prefix, "Background task #{snapshot.id}", "Status: #{status}", snapshot.error, output]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Result.new(text, structured_content: json_snapshot(snapshot))
  end

  defp background_status(%{status: :exited, exit_status: status}), do: "exited (#{status})"
  defp background_status(%{status: :timed_out}), do: "timed out"
  defp background_status(%{status: :failed}), do: "failed"
  defp background_status(%{status: :cancelled}), do: "cancelled"
  # With the elapsed time, so that two polls of a quiet task are two different
  # answers. They were identical, and `Lemieux.Session` counts a round that asks the
  # same thing and gets the same answer as no progress — three polls of a silent
  # test suite stopped the session waiting for it. The elapsed time is also what the
  # model most wants to know.
  defp background_status(%{status: :running, duration_ms: ms}), do: "running for #{ms}ms"

  defp json_snapshot(snapshot) do
    Map.new(snapshot, fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  # The accumulator is `{seen?, pending}`: whether any output has reached the
  # model yet, and an escape sequence cut off at the end of the last chunk
  # (see `Lemieux.Tool.Escapes.strip_chunk/2`). An unfinished sequence left
  # at the end of the stream is dropped with it.
  defp render_events(events, cut) do
    Stream.transform(
      events,
      fn -> {false, ""} end,
      fn
        # A chunk that carried no bytes is not output. Counting it as output
        # suppresses the ending below, and the command comes back as the empty
        # string — the exact shape a model reads as "ran fine, said nothing".
        # A chunk that was nothing but colour codes is no output either.
        {:data, data}, {seen?, pending} ->
          case Escapes.strip_chunk(pending, data) do
            {"", pending} -> {[], {seen?, pending}}
            {clean, pending} -> {[clean], {true, pending}}
          end

        {:failed, reason}, {seen?, _pending} ->
          message = "[the command's output stream failed: #{describe(reason)}]"
          {[{:error, message}], {seen?, ""}}

        {:exit_status, 0}, {seen?, _pending} ->
          text = if seen?, do: "", else: "[the command produced no output]"
          result = command_result(text, %{"status" => "exited", "exit_status" => 0})
          {[{:ok, result}], {true, ""}}

        {:exit_status, status}, {seen?, _pending} ->
          result =
            command_result(note(seen?, "[exit status #{status}]"), %{
              "status" => "exited",
              "exit_status" => status
            })

          {[{:ok, result}], {true, ""}}

        {:timeout, timeout}, {seen?, _pending} ->
          result =
            command_result(note(seen?, timed_out(timeout, cut)), %{
              "status" => "timed_out",
              "timeout_ms" => timeout
            })

          {[{:ok, result}], {true, ""}}

        {:output_limit, bytes}, {seen?, _pending} ->
          result =
            command_result(
              note(seen?, "[output passed #{bytes} bytes; the command was stopped]"),
              %{
                "status" => "output_limit",
                "max_output_bytes" => bytes
              }
            )

          {[{:ok, result}], {true, ""}}
      end,
      fn _acc -> [] end
    )
  end

  # Execution success means Bash ran, not that its command passed. Keep the
  # terminal facts separately so hosts and validators never have to
  # parse (or trust) an exit-status sentence in arbitrary command output.
  defp command_result(text, facts), do: Result.new(text, structured_content: facts)

  defp note(true, text), do: "\n\n" <> text
  defp note(false, text), do: text

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # An environment that could not start the shell at all says why in a
  # sentence (no bash on PATH, say); show the sentence rather than its tuple.
  defp describe_start({:command_start_failed, reason}) when is_binary(reason), do: reason
  defp describe_start(reason), do: describe(reason)

  defp render(acc, note) do
    output =
      acc
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> Tool.sanitize()
      |> Tool.truncate(@max_bytes)

    [text(output), note]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp text(""), do: "[the command produced no output]"
  defp text(output), do: String.trim_trailing(output, "\n")
end
