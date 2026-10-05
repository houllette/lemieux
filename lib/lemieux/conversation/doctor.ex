defmodule Lemieux.Conversation.Doctor do
  @moduledoc """
  What `/doctor` checks, and how it says so.

  `lmx explain` answers "how was this session prepared" as a JSON document for
  a person reading it later; `/doctor` answers "is this session in working
  order" in a sitting, as lines a person reads once. Most of what it reports
  is the session's own account (`Lemieux.Session.info/2`, which carries no
  transcript); the rest is the machine: whether commands get a process group
  of their own, whether `rg` and `git` are there for the search tools and
  `/diff`, whether a command sandbox could be used.

  `gather/1` does the asking and `format/1` does the words, so the words are
  tested against a fixed set of facts and the asking against a real session.
  A session that does not answer is reported as such rather than taking the
  report with it, because the moment somebody types `/doctor` is the moment
  something is already wrong.

  ## What `/undo` covers

  The checkpoints row says what `/undo` can take back here, not only that
  checkpoints are on. It used to say "/undo and /rewind put files back"
  wherever they were on, and outside a git repository that read as a
  promise about everything the agent did: there, what a command changes is
  never recorded, and the first a person heard of it was an `/undo` after
  `rm -rf build` that named the command as not undone. `undo_coverage/1` is
  that rule for a host that records commands at all
  (`Lemieux.Extensions.Checkpoints` with `git: true`, as `lmx` applies it),
  and the terminal UI's startup notice and `lmx run` say it from the same
  function, so for `lmx` the three cannot disagree about a directory.

  Those two take a host that records checkpoints to record commands as
  well. A host that applied the extension without `git: true` is told apart
  only here, from the extension's own record in the session, which the
  session hands over only with a copy of its transcript — the price of
  `/doctor`, not of every sitting's start. Inside a repository such a host
  gets no startup notice, while this row says that it records no commands.
  """

  alias Lemieux.Checkpoint.Git
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Environment
  alias Lemieux.Environment.Local.ExCmd
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Extensions.Permissions
  alias Lemieux.ModelSpec
  alias Lemieux.Session

  @typedoc """
  What `/undo` can take back in a working directory: `:commands` when what
  commands change there is recorded as well as what the file tools change,
  `{:file_tools, why}` when only the file tools are recorded, `why` a phrase
  for a person, or `:unknown` when `git` did not answer in time.
  """
  @type undo_coverage :: :commands | {:file_tools, String.t()} | :unknown

  # As long as `Lemieux.Extensions.EnvironmentContext` gives `git status`.
  # The terminal UI asks as a sitting opens, on the process that draws the
  # screen, so a repository on a hung network mount, or whose own
  # configuration runs something slow, costs the notice and not the screen.
  @git_timeout_ms 2_000

  @typedoc "What `gather/1` found, the input `format/1` reads."
  @type facts :: %{
          optional(:info) => map() | {:error, String.t()},
          optional(:key) => {:present | :missing, String.t()} | :not_required | :unknown,
          optional(:extensions) => [String.t()],
          optional(:permissions) => {String.t(), [String.t()]} | nil,
          optional(:checkpoints) => Path.t() | nil,
          optional(:undo) => undo_coverage() | nil,
          optional(:environment) => map(),
          optional(:platform) => map()
        }

  @doc """
  Collects the facts for `host`'s session. Blocks on the session and the
  filesystem, so a host calls it from work handed to
  `Lemieux.Conversation.Dispatch.run/3`.
  """
  @spec gather(host :: Dispatch.t()) :: facts()
  def gather(%Dispatch{} = host) do
    info = info(host.session)
    environment = Dispatch.environment(host)
    applied = applied(host.session)

    %{
      info: info,
      key: key(info),
      extensions: extensions(applied),
      permissions: permissions(host.permissions),
      checkpoints: host.checkpoints,
      undo: undo(host.checkpoints, cwd(host, info), applied),
      environment: %{
        sandbox: Sandbox.describe(environment),
        name: Environment.name(environment),
        credentials: Environment.credentials(environment)
      },
      platform: platform()
    }
  end

  @doc """
  What `/undo` can take back for a session working in `cwd`, whose host
  records checkpoints with commands — `Lemieux.Extensions.Checkpoints` with
  `git: true`, as `lmx` applies it.

  `:commands` where commands are snapshotted too: `cwd` is inside a git work
  tree that this machine's `git` can read, and not in a directory its
  repository ignores. Otherwise `{:file_tools, why}`: `"not a git
  repository"`, `"git was not found"`, `"the git repository ignores this
  directory"` or `"the git repository's work tree is set to another
  directory"` (a `core.worktree` elsewhere). This is the rule
  `Lemieux.Checkpoint.Git.snapshot/2` applies before each command, asked with
  `Lemieux.Checkpoint.Git.locate/1` — the checks a snapshot makes first,
  which run nothing the repository configures — rather than a snapshot,
  which would write objects into the repository to answer a question.

  Runs `git` — one process, two in a subdirectory of a repository — so it
  blocks: the terminal UI asks once per sitting, `lmx run` at its first
  command, and `/doctor` off the draw loop. It blocks for at most
  `:timeout_ms` (default #{@git_timeout_ms}), and is `:unknown` past it.
  """
  @spec undo_coverage(cwd :: Path.t(), opts :: keyword()) :: undo_coverage()
  def undo_coverage(cwd, opts \\ []) when is_binary(cwd) do
    task = Task.async(fn -> coverage(cwd) end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, @git_timeout_ms)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, coverage} -> coverage
      _late -> :unknown
    end
  end

  defp coverage(cwd) do
    case Git.locate(cwd) do
      {:ok, _repository} ->
        :commands

      :skipped ->
        {:file_tools, "not a git repository"}

      {:error, :git_not_found} ->
        {:file_tools, "git was not found"}

      {:error, :ignored_working_directory} ->
        {:file_tools, "the git repository ignores this directory"}

      {:error, :foreign_work_tree} ->
        {:file_tools, "the git repository's work tree is set to another directory"}
    end
  end

  @doc """
  The sentence a front end says once when what commands change in `cwd` is
  not recorded for `/undo` (`undo_coverage/2`), or `nil` when they are, or
  when `git` did not answer in time: a notice said on a guess would be one
  more thing to distrust.
  """
  @spec undo_notice(cwd :: Path.t()) :: String.t() | nil
  def undo_notice(cwd) when is_binary(cwd) do
    case undo_coverage(cwd) do
      {:file_tools, why} -> file_tools_only(why)
      _commands_or_unknown -> nil
    end
  end

  defp file_tools_only(why),
    do: "/undo covers file-tool edits only here: #{why}, so what commands change is not recorded"

  # Asked only where checkpoints are on: off, `/undo` has nothing at all,
  # and the row says that instead. A host that applied the extension
  # without `git: true` records the file tools alone wherever it runs, and
  # the extension's own description in the session says so.
  defp undo(dir, cwd, applied) when is_binary(dir) and is_binary(cwd) do
    if commands_recorded?(applied),
      do: undo_coverage(cwd),
      else: {:file_tools, "this host does not record commands"}
  end

  defp undo(_dir, _cwd, _applied), do: nil

  # The provenance `Lemieux.Harness` records names a module as `inspect/1`
  # spells it. A session with no record of the extension — a host that
  # recorded checkpoints by other means — is taken to record commands, the
  # rule the row then states.
  defp commands_recorded?(applied) do
    case Enum.find(applied, &(Map.get(&1, "module") == inspect(Checkpoints))) do
      %{"options" => %{"git" => git}} -> git == true
      _not_described -> true
    end
  end

  defp cwd(%Dispatch{cwd: cwd}, _info) when is_binary(cwd), do: cwd
  defp cwd(_host, %{cwd: cwd}) when is_binary(cwd), do: cwd
  defp cwd(_host, _info), do: nil

  defp info(nil), do: {:error, "no session is running"}

  defp info(session) do
    Session.info(session, 10_000)
  catch
    :exit, _reason -> {:error, "the session did not answer"}
  end

  # The key the model's provider reads, by the same lookup req_llm makes:
  # application config, then the environment variable. Present is reported
  # as present and unverified — only a request proves a key works.
  defp key({:error, _reason}), do: :unknown

  defp key(%{model: model}) do
    with name when is_binary(name) <- ModelSpec.provider(model),
         provider when is_atom(provider) and not is_nil(provider) <- req_llm_provider(name),
         {:ok, module} <- ReqLLM.provider(provider),
         true <- function_exported?(module, :default_env_key, 0) do
      variable = ReqLLM.Keys.env_var_name(provider)

      configured =
        Application.get_env(:req_llm, ReqLLM.Keys.config_key(provider)) ||
          System.get_env(variable)

      if is_binary(configured) and configured != "",
        do: {:present, variable},
        else: {:missing, variable}
    else
      false -> :not_required
      _unknown -> :unknown
    end
  end

  defp req_llm_provider(name),
    do: Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == name))

  # Read from the harness context the session was started with, the one
  # place that names every extension that shaped it — there before the first
  # request, unlike the per-request harness snapshot — and what each was
  # applied with. The snapshot call copies the transcript, which is why this
  # is `/doctor` and not a status line.
  defp applied(nil), do: []

  defp applied(session) do
    session
    |> Session.snapshot(10_000)
    |> Map.get(:harness_context, %{})
    |> get_in(["extensions", "applied"])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  catch
    :exit, _reason -> []
  end

  defp extensions(applied) do
    applied
    |> Enum.flat_map(fn
      %{"module" => module} when is_binary(module) -> [short_module(module)]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp short_module("Elixir." <> module), do: short_module(module)
  defp short_module("Lemieux.Extensions." <> module), do: module
  defp short_module(module), do: module

  defp permissions(nil), do: nil

  defp permissions(handle),
    do: {handle |> Permissions.mode() |> Permissions.label(), Permissions.remembered(handle)}

  defp platform do
    %{
      os: os(),
      process_groups?: ExCmd.process_groups?(),
      rg: System.find_executable("rg"),
      git: System.find_executable("git"),
      sandbox: Sandbox.available(:auto)
    }
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {:win32, _flavour} -> "Windows"
      {family, name} -> "#{family}/#{name}"
    end
  end

  @doc "The facts as the lines `/doctor` prints."
  @spec format(facts :: facts()) :: String.t()
  def format(facts) when is_map(facts) do
    [
      "lmx doctor"
      | [
          session_rows(facts[:info]),
          key_rows(facts[:key]),
          context_rows(facts[:info]),
          limit_rows(facts[:info]),
          tool_rows(facts[:info]),
          mcp_rows(facts[:info]),
          permission_rows(facts),
          checkpoint_rows(facts),
          environment_rows(facts[:environment]),
          platform_rows(facts[:platform]),
          extension_rows(facts[:extensions])
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
    ]
    |> Enum.join("\n")
  end

  defp row(label, text), do: "  " <> String.pad_trailing(label, 13) <> text

  defp session_rows({:error, reason}), do: row("session", reason)

  defp session_rows(%{} = info) do
    [
      row("session", "#{info.id} · #{info.status}"),
      row("model", "#{info.model} · effort #{Map.get(info, :reasoning_effort, "default")}"),
      row("directory", info.cwd)
    ]
  end

  defp session_rows(_missing), do: nil

  defp key_rows({:present, variable}), do: row("key", "#{variable} is set (not verified)")

  defp key_rows({:missing, variable}),
    do: row("key", "missing · set #{variable}, or switch with /provider")

  defp key_rows(:not_required), do: row("key", "not required by this provider")
  defp key_rows(:unknown), do: row("key", "unknown for this provider or route")
  defp key_rows(_missing), do: nil

  defp context_rows(%{context_window_known?: false}),
    do: row("context", "window unknown · planning with a conservative guess")

  defp context_rows(%{context_window_known?: true}), do: row("context", "window known")
  defp context_rows(_info), do: nil

  defp limit_rows(%{} = info) do
    requests =
      case Map.get(info, :max_requests) do
        nil -> "#{Map.get(info, :requests, 0)} requests, no cap"
        cap -> "#{Map.get(info, :requests, 0)}/#{cap} requests"
      end

    spend =
      case {Map.get(info, :spent_usd), Map.get(info, :max_cost_usd)} do
        {_spent, nil} -> "no spending cap"
        {spent, cap} when is_number(spent) -> "#{usd(spent)} of #{usd(cap)}"
        {_unknown, cap} -> "spend unmeasured, cap #{usd(cap)}"
      end

    row("limits", requests <> " · " <> spend)
  end

  defp limit_rows(_info), do: nil

  defp tool_rows(%{tools: [_ | _] = tools}), do: row("tools", Enum.join(tools, ", "))
  defp tool_rows(%{tools: []}), do: row("tools", "none")
  defp tool_rows(_info), do: nil

  defp mcp_rows(%{mcp: [_ | _] = servers}) do
    [first | rest] = Enum.map(servers, &server/1)
    [row("mcp", first) | Enum.map(rest, &row("", &1))]
  end

  defp mcp_rows(%{mcp: []}), do: row("mcp", "no servers")
  defp mcp_rows(_info), do: nil

  defp server(server) do
    [
      Map.get(server, :name),
      Map.get(server, :transport),
      server |> Map.get(:status) |> status(),
      tools(Map.get(server, :tool_count)),
      Map.get(server, :error)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp status(nil), do: nil
  defp status(:needs_auth), do: "needs authorization · /mcp to sign in"
  defp status(status), do: status |> to_string() |> String.replace("_", " ")

  defp tools(count) when is_integer(count) and count > 0, do: "#{count} tools"
  defp tools(_count), do: nil

  defp permission_rows(%{permissions: {mode, []}}), do: row("permissions", mode)

  defp permission_rows(%{permissions: {mode, remembered}}),
    do: row("permissions", "#{mode} · always allowed: #{Enum.join(remembered, ", ")}")

  defp permission_rows(_facts),
    do: row("permissions", "off · every tool call runs without asking")

  # What /undo can take back, not only that checkpoints are on: see "What
  # `/undo` covers" in the moduledoc. Facts gathered without a working
  # directory state the rule rather than an answer for this directory.
  defp checkpoint_rows(%{checkpoints: dir} = facts) when is_binary(dir),
    do: row("checkpoints", "#{dir} · #{covers(facts[:undo])} · /undo, /rewind, /redo")

  defp checkpoint_rows(_facts), do: row("checkpoints", "off · /undo has nothing to put back")

  defp covers({:file_tools, why}), do: "file tools only: #{why}"
  defp covers(_commands_or_unknown), do: "file tools, and commands in a git repository"

  defp environment_rows(%{} = environment) do
    where =
      case environment.sandbox do
        %{"backend" => backend} = sandbox ->
          network = if sandbox["network"], do: "network allowed", else: "no network"
          "sandboxed (#{backend}, #{network})"

        _local ->
          "#{where(environment.name)}, not sandboxed"
      end

    # `Lemieux.Environment.credentials/1` answers an already normalised policy.
    credentials =
      case environment.credentials do
        {:scrub, []} -> "credentials: keys and tokens withheld"
        {:scrub, allow} -> "credentials: withheld except #{Enum.join(allow, ", ")}"
        _inherit -> "credentials: inherited"
      end

    row("commands", where <> " · " <> credentials)
  end

  defp environment_rows(_missing), do: nil

  defp where("Lemieux.Environment.Local"), do: "this machine"
  defp where(name), do: name

  defp platform_rows(%{} = platform) do
    groups =
      if platform.process_groups?,
        do: "process groups: yes",
        else: "process groups: no (a cancelled command may leave children running)"

    [
      row("platform", "#{platform.os} · #{groups}"),
      row("", "rg: #{found(platform.rg, "grep falls back to git or a directory walk")}"),
      row("", "git: #{found(platform.git, "/diff and git checkpoints are unavailable")}"),
      row("", "sandbox: #{sandbox(platform.sandbox)}")
    ]
  end

  defp platform_rows(_missing), do: nil

  defp found(nil, consequence), do: "missing · #{consequence}"
  defp found(path, _consequence), do: path

  defp sandbox({:ok, backend, path}), do: "#{backend} available (#{path})"
  defp sandbox({:error, reason}), do: "unavailable · #{reason}"
  defp sandbox(_other), do: "unknown"

  defp extension_rows([_ | _] = extensions), do: row("extensions", Enum.join(extensions, ", "))
  defp extension_rows(_none), do: nil

  defp usd(amount) when is_number(amount),
    do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)

  defp usd(_amount), do: "unknown"
end
