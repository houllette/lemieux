defmodule Lemieux.Extensions.Verify do
  @moduledoc """
  Runs the project's own check after a turn that edited files, and gives the
  model a bounded number of chances to fix what the check reports.

  A model says "done" when it believes it is done. The prompt asks it to run
  the tests, and capable models usually do; the ones that do not are the ones
  whose "done" most needs checking. This makes the check something the model
  cannot skip: when a turn that changed files is about to stop, the project's
  verification command runs — found from its conventions by
  `Lemieux.Extensions.Verify.Discovery`, or named by the host — and a
  failure becomes one more turn with the failing output in front of the
  model. The measured version of this (the `verifier` example, 2026-09-17)
  retried in one run of sixteen and turned that miss into a pass.

  ## When it runs

  At an ordinary stop (`:stop` — never after a cancel, an error or a spent
  budget), when:

    * it is enabled — the `:enabled` option, overridden at runtime by
      `set_enabled/2`, which is what a host's `/verify` toggles;
    * a tool in `:editing_tools` (default `write`, `edit`, `apply_patch`)
      succeeded since the person's prompt or since the last check;
    * the model did not itself run exactly the verification command, and see
      it pass, after its last edit — the check would only repeat that run;
    * fewer than `:max_continuations` (default 2) checks have already sent
      the model back during this prompt;
    * a command was named or discovered. No convention means no check,
      silently: guessing at one would fail every turn of a project it does
      not fit.

  Edits made through `bash` do not count on their own. Counting every
  command would run a test suite after a turn that only listed a directory,
  and nothing about a shell command says which ones wrote. A host that wants
  them counted adds `"bash"` to `:editing_tools`.

  ## What the model is told, and why it can say no

  The failure arrives as a message marked `[lmx verify]`, with the
  command, how it ended and the tail of its output. It also says the model
  may stop without further changes when a failure was already there or cannot
  be fixed here. A project whose suite was red before the session started
  would otherwise spend every allowance on failures the model did not cause;
  a model that answers without editing ends the loop, because a check runs
  only after edits.

  Every count this uses — continuations spent, edits since the last check —
  is read from the transcript, never kept in a process: it survives resume,
  and a cancelled check leaves nothing half-updated. The toggle and the last
  result are a session document (`lemieux.verify`), so a screen that
  follows `{:entry, entry}` events can show them.

  ## Where it runs

  Through `Lemieux.Environment`, in the session's working directory: the
  environment the hook context names when the session supplies one, else
  `:environment` from the options, else the harness's, else the local
  machine. The check is bounded by `:timeout_ms` (default five minutes) and
  can be cancelled with the turn.

  ## Under the session's permission policy

  The check is a command the repository chose — `tests/run.sh` and
  `make test` are whatever the checkout says they are — so before it runs it
  is put to the session's `before_tool_call` hooks as the `bash` call
  `bash(command)` would be, with the `bash` tool's descriptor. Whatever
  answers a command the model runs answers this one:

    * with no policy (the default, "full auto") it runs unasked;
    * `Lemieux.Extensions.Permissions` in `:accept_edits` or `:ask` asks,
      and the approval card shows the command; `"Bash(make test)"` in
      `allow` lets it run unasked, and a deny rule such as `"Bash"` refuses
      it; with nobody to ask (`lmx run`, `non_interactive: :deny`) a check
      that would ask is refused;
    * a hook that rewrites the command runs the rewritten one.

  A refused check is not a failed one. Nothing ran, so there is nothing for
  the model to fix and the turn ends as it would have; the refusal is
  recorded as the last result (`status` `"denied"`, with the `reason`), which
  is what `/verify` shows. It used to bypass all of this: a `Bash` deny rule
  that refused `make test` from the model let the same command run here,
  because the check never was a tool call.

  The hooks are the session's own, from the stop hook's context, not the
  ones present when this extension was applied: a policy applied after it,
  or a host's final say, must hold here as it does for every tool call
  (`Lemieux.Tools.run/5` records the same rule).

  ## Inside the undo net

  The check changes files as surely as the model's own commands do — a
  formatter run as part of it, fixtures it regenerates, a build's output.
  Given `:checkpoints`, the directory `Lemieux.Extensions.Checkpoints`
  records into, it runs inside a window of its own
  (`Lemieux.Checkpoint.around/4`), recorded with the turn whose edits it
  checked. An undo of that turn takes back what the check changed with the
  edits, as far as it would for a command: what a git snapshot holds.
  `Lemieux.Checkpoint` lists what one leaves out — an ignored file the
  check changed is named but not put back, and a change inside a wholly
  ignored directory such as `_build/` is not seen at all, nor is an empty
  directory the check created. Where it could not record the check — no
  git repository — the undo names it among what it did not reverse.
  Without `:checkpoints`, an undo put the model's edits back and said
  nothing of the check's. `lmx` passes the directory whenever it records
  checkpoints.

  A file the person saves while the check runs cannot be told from the
  check's own change, so it goes back with the check, as it would with a
  command (`Lemieux.Checkpoint.redo/3` takes such an undo back). A check is
  usually a test suite, the longest command of a turn, so that is likelier
  here than anywhere else. Recording costs two snapshots per check.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Checkpoint
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Verify.Check
  alias Lemieux.Extensions.Verify.Discovery
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tools.Bash
  alias Lemieux.Transcript

  @namespace "lemieux.verify"
  @marker "[lmx verify]"

  @type t :: %__MODULE__{
          command: :auto | String.t(),
          max_continuations: non_neg_integer(),
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          excerpt_bytes: pos_integer(),
          editing_tools: [String.t()],
          enabled: boolean(),
          environment: Environment.t() | nil,
          cwd: Path.t() | nil,
          checkpoints: Path.t() | nil
        }

  defstruct command: :auto,
            max_continuations: 2,
            timeout_ms: 300_000,
            max_output_bytes: 16_384,
            excerpt_bytes: 4_096,
            editing_tools: ~w(write edit apply_patch),
            enabled: true,
            environment: nil,
            cwd: nil,
            checkpoints: nil

  @doc """
  Options: `:command` (a string, or `:auto` to discover one — the default),
  `:max_continuations`, `:timeout_ms`, `:max_output_bytes`,
  `:excerpt_bytes`, `:editing_tools`, `:enabled`, `:environment`, `:cwd`
  (where discovery looks when the hook context names none) and
  `:checkpoints` (the checkpoint directory the check is recorded in,
  expanded here as `Lemieux.Extensions.Checkpoints` expands its `:dir`; see
  "Inside the undo net"). Unknown or malformed options are an error rather
  than a check that silently never runs.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    known = __MODULE__ |> struct() |> Map.from_struct() |> Map.keys()

    case Keyword.keys(opts) -- known do
      [] -> with {:ok, config} <- validate(struct(__MODULE__, opts)), do: {:ok, expanded(config)}
      unknown -> {:error, "unknown verify options: #{inspect(unknown)}"}
    end
  end

  # Expanded once, here, as `Lemieux.Extensions.Checkpoints` expands its own
  # `:dir`. Kept relative, a path a host gave both extensions named one
  # directory to the undo and, after the VM's working directory moved,
  # another to the check: recorded where no undo of the turn looks.
  defp expanded(%__MODULE__{checkpoints: nil} = config), do: config

  defp expanded(%__MODULE__{checkpoints: dir} = config),
    do: %{config | checkpoints: Path.expand(dir)}

  defp validate(%__MODULE__{} = config) do
    Enum.find_value(
      [
        {config.command == :auto or (is_binary(config.command) and config.command != ""),
         "command must be :auto or a non-empty string"},
        {is_integer(config.max_continuations) and config.max_continuations in 0..10,
         "max_continuations must be an integer from 0 to 10"},
        {positive?(config.timeout_ms), "timeout_ms must be a positive integer"},
        {positive?(config.max_output_bytes), "max_output_bytes must be a positive integer"},
        {positive?(config.excerpt_bytes), "excerpt_bytes must be a positive integer"},
        {is_list(config.editing_tools) and Enum.all?(config.editing_tools, &is_binary/1),
         "editing_tools must be a list of tool names"},
        {is_boolean(config.enabled), "enabled must be true or false"},
        {is_nil(config.checkpoints) or
           (is_binary(config.checkpoints) and config.checkpoints != ""),
         "checkpoints must be a directory path"}
      ],
      {:ok, config},
      fn
        {true, _problem} -> nil
        {false, problem} -> {:error, "verify: " <> problem}
      end
    )
  end

  defp positive?(value), do: is_integer(value) and value > 0

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %__MODULE__{} = config) do
    config = %{config | environment: config.environment || harness.environment}
    Harness.append_hooks(harness, stop: &stop(config, &1, &2))
  end

  @impl Lemieux.Extension
  def describe(%__MODULE__{} = config) do
    %{
      "command" => if(config.command == :auto, do: "auto", else: config.command),
      "max_continuations" => config.max_continuations,
      "enabled" => config.enabled
    }
  end

  @doc "The session document namespace the toggle and last result live under."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "The prefix every message this extension sends the model starts with."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Turns verification on or off for this session, from now on — what a host's
  `/verify` does. Recorded in the transcript, so it survives resume.
  """
  @spec set_enabled(session :: Session.session(), enabled? :: boolean()) ::
          {:ok, map()} | {:error, term()}
  def set_enabled(session, enabled?) when is_boolean(enabled?) do
    with {:ok, %{revision: revision, value: value}} <- Session.document(session, @namespace) do
      current = value || %{"version" => 1}
      next = Map.put(current, "enabled", enabled?)

      if next == value,
        do: {:ok, %{revision: revision, value: value}},
        else: Session.put_document(session, @namespace, revision, next)
    end
  end

  @doc """
  What a host shows: `enabled` is the runtime toggle, or `nil` when nobody
  has toggled it (the extension's `:enabled` option applies); `last` is the
  most recent check's `status`, `command`, `discovered_from`, `exit_status`
  and `duration_ms` — or, for a check the permission policy refused, status
  `"denied"` with its `reason` — or `nil`.
  """
  @spec status(session :: Session.session()) ::
          {:ok, %{enabled: boolean() | nil, last: map() | nil}} | {:error, term()}
  def status(session) do
    with {:ok, %{value: value}} <- Session.document(session, @namespace) do
      value = value || %{}
      {:ok, %{enabled: Map.get(value, "enabled"), last: Map.get(value, "last")}}
    end
  end

  @doc false
  @spec stop(config :: t(), reason :: atom(), context :: map()) :: :allow | {:deny, String.t()}
  def stop(%__MODULE__{} = config, :stop, %{session: session} = context) do
    cwd = Map.get(context, :cwd) || config.cwd || File.cwd!()

    with {:ok, document} <- Session.document(session, @namespace),
         true <- enabled?(config, document.value),
         %{entries: entries} <- Session.snapshot(session, :timer.seconds(30)),
         run = current_run(entries),
         used = continuations(run),
         true <- used < config.max_continuations,
         since = since_last_check(run),
         true <- edited?(since, config.editing_tools),
         {:ok, discovery} <- discover(config, cwd),
         false <- model_checked?(since, discovery.command, config.editing_tools) do
      case permitted(discovery.command, cwd, context) do
        {:ok, command} ->
          result = check(config, command, cwd, context)
          record(session, document, result, discovery)
          decide(config, result, discovery, used + 1)

        {:deny, reason} ->
          denied = %{"status" => "denied", "command" => discovery.command, "reason" => reason}
          record(session, document, denied, discovery)
          :allow
      end
    else
      _skip -> :allow
    end
  end

  def stop(_config, _reason, _context), do: :allow

  defp check(%__MODULE__{checkpoints: nil} = config, command, cwd, context),
    do: run_check(config, command, cwd, context)

  # In a window of its own, recorded with the current turn — the one whose
  # edits are being checked, since the continuation a failure sends is not
  # a new prompt and starts no turn. See "Inside the undo net" above.
  defp check(%__MODULE__{checkpoints: store} = config, command, cwd, context) do
    checkpoint = %{
      cwd: cwd,
      session_id: Map.get_lazy(context, :session_id, fn -> Session.id(context.session) end),
      supervisor: Map.get(context, :supervisor)
    }

    Checkpoint.around(
      store,
      checkpoint,
      fn -> run_check(config, command, cwd, context) end,
      subject: "the post-edit check " <> Checkpoint.subject(command)
    )
  end

  defp run_check(config, command, cwd, context) do
    Check.run(command, cwd,
      environment: Map.get(context, :environment) || config.environment,
      timeout_ms: config.timeout_ms,
      max_output_bytes: config.max_output_bytes
    )
  end

  # The check as the `bash` call that would run it, put to the hooks a tool
  # call meets. See "Under the session's permission policy" above. The call
  # id is fresh per check: a question parked under it is answered by
  # `Lemieux.Session.resolve_tool/3` like any other.
  defp permitted(command, cwd, context) do
    call = %{
      id: "verify-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      name: "bash",
      arguments: %{"command" => command}
    }

    tool_context =
      context
      |> Map.put(:cwd, cwd)
      |> Map.put(:tool_descriptor, Descriptor.to_map(Tool.descriptor(Bash)))

    case Hooks.before_tool_call(Map.get(context, :hooks) || [], call, tool_context) do
      {:ok, %{"command" => rewritten}} when is_binary(rewritten) and rewritten != "" ->
        {:ok, rewritten}

      {:ok, _arguments} ->
        {:ok, command}

      {:deny, reason} ->
        {:deny, reason}
    end
  end

  defp enabled?(_config, %{"enabled" => enabled}) when is_boolean(enabled), do: enabled
  defp enabled?(config, _value), do: config.enabled

  defp discover(%__MODULE__{command: :auto}, cwd), do: Discovery.discover(cwd)
  defp discover(%__MODULE__{command: command}, cwd), do: Discovery.discover(cwd, command: command)

  # Everything since the person last spoke. A message any stop hook wrote —
  # this one's, or another's sending the model back to its plan — is a
  # continuation, not a prompt, so it does not end the run. The marker
  # check is for transcripts written before the session marked them.
  defp current_run(entries) do
    entries
    |> Enum.reverse()
    |> Enum.take_while(&(not prompt?(&1)))
    |> Enum.reverse()
  end

  defp prompt?(%Entry{type: :user} = entry) do
    not Transcript.stop_hook?(entry) and not ours?(entry)
  end

  defp prompt?(_entry), do: false

  defp continuations(run), do: Enum.count(run, &ours?/1)

  defp ours?(%Entry{type: :user, payload: %{"text" => @marker <> _rest}}), do: true
  defp ours?(_entry), do: false

  defp since_last_check(run) do
    run
    |> Enum.reverse()
    |> Enum.take_while(&(not ours?(&1)))
    |> Enum.reverse()
  end

  defp edited?(entries, tools), do: Enum.any?(entries, &edit?(&1, tools))

  defp edit?(%Entry{type: :tool_result, payload: %{"name" => name, "error" => false}}, tools),
    do: name in tools

  defp edit?(_entry, _tools), do: false

  # A run of exactly this command, alone or as one `&&`/`;` step, that exited
  # zero after the last edit. A focused run (`mix test some_test.exs`) or a
  # pipeline (`mix test | tail`, whose status is `tail`'s) is not the check.
  defp model_checked?(entries, command, tools) do
    entries
    |> Enum.reverse()
    |> Enum.take_while(&(not edit?(&1, tools)))
    |> Enum.any?(&passing_run_of?(&1, command))
  end

  defp passing_run_of?(
         %Entry{
           type: :tool_result,
           payload: %{
             "name" => "bash",
             "error" => false,
             "arguments" => %{"command" => ran},
             "structured_content" => %{"exit_status" => 0}
           }
         },
         command
       )
       when is_binary(ran) do
    ran
    |> String.split(["&&", ";"])
    |> Enum.any?(&(normalize(&1) == normalize(command)))
  end

  defp passing_run_of?(_entry, _command), do: false

  defp normalize(command), do: command |> String.split() |> Enum.join(" ")

  defp record(session, document, result, discovery) do
    last =
      result
      |> Map.take(~w(status exit_status duration_ms command reason))
      |> Map.put("discovered_from", discovery.discovered_from)

    value = Map.put(document.value || %{"version" => 1}, "last", last)

    # A toggle that landed while the check ran wins; the result is only a
    # display, and the transcript already carries the message the model got.
    _recorded = Session.put_document(session, @namespace, document.revision, value)
    :ok
  end

  defp decide(_config, %{"status" => "passed"}, _discovery, _check), do: :allow

  # The command could not run at all — not installed, a broken pipe. The
  # model cannot fix the machine, and telling it the check "failed" would
  # send it hunting for a bug in code that was never exercised. A shell
  # reports a missing or non-executable command as 127 or 126, which is the
  # same news arriving as an exit status.
  defp decide(_config, %{"status" => "failed_to_run"}, _discovery, _check), do: :allow

  defp decide(_config, %{"status" => "failed", "exit_status" => status}, _discovery, _check)
       when status in [126, 127],
       do: :allow

  defp decide(config, result, discovery, check) do
    {:deny, feedback(config, result, discovery, check)}
  end

  defp feedback(config, result, discovery, check) do
    """
    #{@marker} After your changes, `#{discovery.command}` (#{source(discovery)}) #{ending(result)}.
    Fix what your changes broke, then finish again. If a failure was there before you started, \
    or cannot be fixed here, say so plainly and stop without making further changes. \
    (Check #{check} of #{config.max_continuations}.)

    Output (the end of it):
    ```
    #{Check.excerpt(result["output"], config.excerpt_bytes)}
    ```
    """
  end

  defp source(%{discovered_from: "command"}), do: "the configured check"
  defp source(%{discovered_from: file}), do: "found from #{file}"

  defp ending(%{"status" => "failed", "exit_status" => status}),
    do: "failed with exit status #{status}"

  defp ending(%{"status" => "timed_out", "timeout_ms" => timeout}),
    do: "did not finish within #{div(timeout, 1000)} seconds"

  defp ending(%{"status" => "output_limit"}),
    do: "stopped after producing more output than the environment allows"
end
