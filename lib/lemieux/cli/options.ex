defmodule Lemieux.CLI.Options do
  @moduledoc """
  The options every `lmx` command that runs an agent shares.

  Precedence is flag, then environment, then personal config, then default — the ordinary shape, and
  worth stating because the environment is how somebody pins a model for a
  whole shell without repeating themselves, while a flag is how they override
  it for one command.

  `given` keeps the configuration flags that were actually typed, which
  resuming needs and the resolved values cannot answer: `model` always holds
  something, so a command that passed it unconditionally would override the
  model a resumed transcript recorded with this build's default every time. A
  flag is an instruction; an environment variable is ambient, and does not
  silently change what an existing conversation was running as. Runtime seams
  are different: `base_url` deliberately applies to resumed work because the
  host doing the resuming owns its current network route.

  Skill and plugin values are parsed here because the TUI shares this common
  flag surface. Only the TUI turns them into a discovered workspace; the
  one-shot runner rejects them rather than pretending to apply them.

  `extensions` is the person's own code, selected and not yet loaded: the
  config file's `"extensions"` names first, then `--extension NAME` and
  `--extension-dir PATH` in the order typed. Names are checked here so a
  path or a module spelt into `--extension` is refused before anything
  reads the disk; `Lemieux.CLI.Extensions` says what a name is and why a
  project-level directory needs the explicit flag.

  ## Which flags a command takes

  `parse/2` with `command:` accepts only the switches that command uses, so
  `lmx log --model x` says `--model` does not apply to `log` instead of
  silently ignoring it, and a flag given without its value, or with one of
  the wrong type, is named as exactly that rather than as an unrecognised
  option. `parse/1` accepts every switch, for callers that share this
  surface without being one of the commands.

  ## Personal state, and what `--config none` means

  `state_dir` is where `lmx` keeps what it remembers between runs — the last
  model, trusted repository MCP servers, checkpoints for `/undo`, remembered
  permission rules, the log file: `LMX_HOME` when it is set, else the config
  file's directory (`~/.lmx`). Under `--config none` (or `LMX_CONFIG=none`)
  with no `LMX_HOME` it is `nil`: such a run reads no personal settings and
  none of that state, keeps no log, and does not guess a model from
  whichever credentials the environment or a local Ollama happens to offer,
  which is what makes it repeatable — the test suite runs this way. The
  features that need a place to write say so rather than writing to the home
  directory anyway.

  It is not a run that leaves the home directory alone, though. Transcripts
  are not personal state and still go to `~/.lmx/sessions` (`--sessions-dir`
  or `LMX_SESSIONS_DIR` moves them), as MCP OAuth tokens still go to
  `~/.lmx/mcp-credentials.json` (`--credentials` or `LMX_CREDENTIALS`), and
  a crash dump to `~/.lmx/crash` (`ERL_CRASH_DUMP`;
  `Lemieux.CLI.crash_state_dir/2`). And an `LMX_HOME` that is set names a
  state directory under `--config none` too, which brings back everything
  above that lives in one — the remembered model, and with it the guessing
  (`Lemieux.CLI.Models`) — and leaves only the config file unread.

  A default config file that cannot be created — a read-only home directory,
  a CI container — also leaves `state_dir` `nil`, since there is nowhere to
  write, but it is not a hermetic run: nobody asked for one, so
  `Lemieux.CLI.Models` still starts on the provider whose key is set, or on a
  model Ollama serves (`Lemieux.CLI.Config.personal?/1` tells the two apart).
  Treating it as `--config none` used to ignore the keys a container had been
  given and stop asking for a key of the built-in default's provider.

  `model_source` records what chose `model` — `:flag`, `:env`, `:config`,
  `:ixway`, or `:fallback` when nothing did — which is what lets
  `Lemieux.CLI.Models` replace only a model nobody asked for. `local_model`
  is what discovery read about the local Ollama model a start checked with
  the daemon — one `Lemieux.CLI.Models` picked, or a remembered one it found
  still served — its trained context length among it; `nil` otherwise.

  ## An empty variable is an unset one

  `LMX_MODEL=`, `LMX_WEB_SEARCH=`, `LMX_ROUTER=`, `LMX_BASE_URL=` and
  `LMX_IXWAY_URL=` count as not set at all, and so do the paths and the port
  `env/1` lists. A blank value is what a template left unfilled or
  `export NAME=` produces, never a choice: taken literally, `LMX_WEB_SEARCH=`
  was a backend called `""` and every command refused to start, which is
  what copying `.env.example` to `.env` used to do. The on/off switches —
  `LMX_WEB_FETCH`, `LMX_PROJECT_MCP` and `LMX_DELEGATE` — still read empty as
  off, as `docs/cli.md` says of `LMX_WEB_FETCH`. The limits (`LMX_MAX_TURNS`,
  `LMX_MAX_REQUESTS`, `LMX_MAX_COST_USD`, read by `Lemieux.CLI.Limits`) and
  `LMX_EXTENSIONS_DIR` (`Lemieux.CLI.Extensions.default_root/0`) go through
  `env/1` too: a blank limit falls through to the config file, and a blank
  extension root is `~/.lmx/extensions`, never the working directory.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Limits
  alias Lemieux.CLI.OAuth

  # The first row of `Lemieux.CLI.Models.recommended/0`, which a test keeps
  # equal (a module attribute computed from that table would make this
  # module depend on it at compile time, and it depends on this one). It is
  # what a run that chose nothing names until a key or a local model is
  # found — the terminal UI opens its provider panel with no row selected,
  # and `lmx run` stops with a sentence naming no single vendor — and what a
  # hermetic `--config none` run starts on. Changing models or providers
  # remains the ordinary --model/LMX_MODEL override.
  @default_model "anthropic:claude-sonnet-5"

  @typedoc """
  Where in a transcript `lmx fork` starts from: an entry id, a sequence
  number, or a turn.

  One field rather than three because it is one decision with three ways of
  spelling it, and `Lemieux.CLI.History` is the only thing that reads it.
  They were three until `--mouse` pushed the struct past the size at which the
  BEAM stops representing a map compactly, which Credo fails the build over —
  and separating what is only ever read together was what had put it there.
  """
  @type fork_point :: %{
          entry: String.t() | nil,
          seq: non_neg_integer() | nil,
          turn: pos_integer() | nil
        }

  @typedoc """
  What only `lmx` the host decides, kept together because each is about this
  invocation rather than the session: where personal state lives, what chose
  the model, `--continue`, whether the repository's MCP servers were trusted
  for this run, the permission mode and sandbox asked for, and mouse capture.
  One field rather than seven for the reason `t:fork_point/0` is one: the
  struct is at the size where the BEAM stops representing a map compactly.
  """
  @type host :: %{
          state_dir: Path.t() | nil,
          model_source:
            :flag | :env | :config | :ixway | :fallback | :last_used | :credential | :ollama,
          local_model: map() | nil,
          continue: boolean(),
          project_mcp_trusted: boolean(),
          permission_mode: String.t() | nil,
          sandbox: boolean() | nil,
          mouse: boolean()
        }

  @type t :: %__MODULE__{
          config: Config.t() | nil,
          model: String.t(),
          base_url: String.t() | nil,
          ixway: String.t() | nil,
          system: String.t() | nil,
          build_ext: boolean(),
          quota: boolean(),
          extension_profile: Path.t() | nil,
          sessions_dir: Path.t(),
          resume: String.t() | nil,
          at: fork_point(),
          jsonl: boolean(),
          unsafe: boolean(),
          mcp_config: Path.t() | false | nil,
          hooks_config: Path.t() | nil,
          skill_dirs: [Path.t()],
          plugin_dirs: [Path.t()],
          marketplaces: [String.t()],
          plugins: [String.t()],
          credentials: Path.t(),
          context_window: pos_integer() | nil,
          web_search: String.t() | nil,
          web_fetch: boolean(),
          oauth_callback_port: pos_integer(),
          oauth_clients: %{optional(String.t()) => map()},
          elixir: boolean(),
          delegate: boolean(),
          extensions: [Extensions.selection()],
          host: host(),
          given: keyword(),
          argv: [String.t()]
        }

  defstruct [
    :config,
    :model,
    :base_url,
    :ixway,
    :system,
    :extension_profile,
    :sessions_dir,
    :resume,
    :at,
    :mcp_config,
    :hooks_config,
    :credentials,
    :context_window,
    :web_search,
    skill_dirs: [],
    build_ext: false,
    quota: false,
    plugin_dirs: [],
    marketplaces: [],
    plugins: [],
    oauth_callback_port: 8642,
    oauth_clients: %{},
    elixir: false,
    delegate: true,
    web_fetch: false,
    jsonl: false,
    unsafe: false,
    extensions: [],
    host: %{
      state_dir: nil,
      model_source: :fallback,
      local_model: nil,
      continue: false,
      project_mcp_trusted: false,
      permission_mode: nil,
      sandbox: nil,
      mouse: true
    },
    given: [],
    argv: []
  ]

  # Every command reads its store and its settings.
  @common [config: :string, sessions_dir: :string]

  # What starting an agent takes, in `lmx`, `lmx run` and `lmx explain`.
  @agent [
    max_turns: :string,
    max_requests: :string,
    max_cost_usd: :string,
    build_ext: :boolean,
    quota: :boolean,
    extension_profile: :string,
    router: :string,
    model: :string,
    base_url: :string,
    ixway: :string,
    system: :string,
    resume: :string,
    mcp_config: :string,
    project_mcp: :boolean,
    hooks: :string,
    skill_dir: [:string, :keep],
    plugin_dir: [:string, :keep],
    marketplace: [:string, :keep],
    plugin: [:string, :keep],
    credentials: :string,
    context_window: :integer,
    web_search: :string,
    web_fetch: :boolean,
    oauth_callback_port: :integer,
    oauth_client_id: [:string, :keep],
    elixir: :boolean,
    delegate: :boolean,
    extension: [:string, :keep],
    user_extensions: :boolean,
    extension_dir: [:string, :keep],
    permission_mode: :string,
    sandbox: :boolean
  ]

  @command_switches %{
    # `--prompt` is read from `given` by `Lemieux.CLI.TUI` alone, as
    # `--output-format` is by `Lemieux.CLI.Run`: it is the first message of
    # this sitting, not a setting, and the struct is at the field count
    # Credo caps it at. The terminal UI's alone, so `lmx run --prompt` is
    # named as not applying rather than dropped: `run` takes its prompt as
    # an argument.
    tui: @common ++ @agent ++ [mouse: :boolean, continue: :boolean, prompt: :string],
    # `--output-format` and `--bare` are read from `given` by `Lemieux.CLI.Run`
    # alone: they describe how one headless answer is delivered, not a
    # setting any other command could share.
    run: @common ++ @agent ++ [continue: :boolean, output_format: :string, bare: :boolean],
    explain: @common ++ @agent ++ [explain_against: :string],
    log: @common ++ [jsonl: :boolean],
    request: @common,
    fork: @common ++ [at: :string, at_seq: :integer, at_turn: :integer, unsafe: :boolean]
  }

  @switches @command_switches |> Map.values() |> List.flatten() |> Enum.uniq()
  @aliases [m: :model, c: :continue]

  @doc """
  Parses `argv`, returning the options and whatever arguments remain.

  `opts` may name the `:command` being parsed for, which restricts the
  switches to that command's; see the module documentation.
  """
  @spec parse(argv :: [String.t()], opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(argv, opts \\ []) do
    command = Keyword.get(opts, :command)
    switches = Map.get(@command_switches, command, @switches)

    with {parsed, rest, []} <- OptionParser.parse(argv, strict: switches, aliases: @aliases),
         {:ok, config} <- Config.from_cli(parsed, @default_model),
         {:ok, limits} <- Limits.parse(parsed, config),
         {:ok, clients} <- oauth_clients(parsed),
         {:ok, inference} <- Config.inference(config, parsed, @default_model),
         {:ok, web_search} <- web_search(parsed, config),
         {:ok, web_fetch} <- web_fetch(parsed, config, web_search),
         {:ok, extensions} <- extensions(parsed, config) do
      {:ok,
       %__MODULE__{
         config: %{config | limits: limits},
         model: inference[:model],
         host: host(parsed, inference, config),
         ixway: inference[:ixway],
         base_url: inference[:base_url],
         system: parsed[:system] || Config.get(config, "system"),
         build_ext: Keyword.get(parsed, :build_ext, false),
         quota: Keyword.get(parsed, :quota, false),
         extension_profile: parsed[:extension_profile],
         sessions_dir:
           parsed[:sessions_dir] || env("LMX_SESSIONS_DIR") || config_sessions_dir(config),
         resume: parsed[:resume],
         at: %{
           entry: parsed[:at],
           seq: parsed[:at_seq],
           turn: parsed[:at_turn]
         },
         jsonl: parsed[:jsonl] || false,
         unsafe: parsed[:unsafe] || false,
         mcp_config: mcp_config(parsed, config),
         hooks_config: parsed[:hooks],
         skill_dirs: Keyword.get_values(parsed, :skill_dir),
         # Saved selections first, then the ones typed, each once: selecting
         # a plugin is the trust decision (`Lemieux.Extensions.Workspace.Plugin`),
         # and `lmx plugin install` is how a selection is saved.
         plugin_dirs:
           Enum.uniq(
             Enum.map(Config.get(config, "plugin_dirs", []), &Path.expand/1) ++
               Keyword.get_values(parsed, :plugin_dir)
           ),
         marketplaces:
           Enum.uniq(
             Config.get(config, "marketplaces", []) ++ Keyword.get_values(parsed, :marketplace)
           ),
         plugins:
           Enum.uniq(Config.get(config, "plugins", []) ++ Keyword.get_values(parsed, :plugin)),
         credentials: parsed[:credentials] || default_credentials(),
         context_window: parsed[:context_window] || Config.get(config, "context_window"),
         web_search: web_search,
         web_fetch: web_fetch,
         oauth_callback_port: parsed[:oauth_callback_port] || default_callback_port(),
         oauth_clients: clients,
         elixir: Keyword.get(parsed, :elixir, false),
         delegate: delegate(parsed, config),
         extensions: extensions,
         given: parsed,
         argv: rest
       }}
    else
      {:error, reason} -> {:error, reason}
      {_parsed, _rest, [invalid | _]} -> {:error, invalid_option(invalid, command, switches)}
    end
  end

  # One sentence per way a flag can be wrong. OptionParser reports all of
  # them as the same `{flag, value}` pair: an unknown switch, one that exists
  # for another command, one missing its value (`nil`), and one whose value
  # is not the type it takes.
  defp invalid_option({flag, value}, command, switches) do
    key = switch_key(flag)

    cond do
      Keyword.has_key?(switches, key) and is_nil(value) ->
        "missing value for #{flag}"

      Keyword.has_key?(switches, key) ->
        "invalid value for #{flag}: #{inspect(value)} (expected #{expected(Keyword.fetch!(switches, key))})"

      Keyword.has_key?(@switches, key) and not is_nil(command) ->
        "#{flag} does not apply to lmx #{command}"

      true ->
        "unrecognised option #{flag}" <> suggestion(flag, switches)
    end
  end

  defp switch_key("--no-" <> name), do: switch_atom(name)
  defp switch_key("--" <> name), do: switch_atom(name)
  defp switch_key("-" <> name), do: Keyword.get(@aliases, switch_atom(name), switch_atom(name))
  defp switch_key(_flag), do: nil

  defp switch_atom(name) do
    name |> String.replace("-", "_") |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp expected(:integer), do: "an integer"
  defp expected([type, :keep]), do: expected(type)
  defp expected(:boolean), do: "no value"
  defp expected(_type), do: "a value"

  defp suggestion("--" <> name, switches) do
    known =
      Enum.map(switches, fn {key, _type} ->
        key |> Atom.to_string() |> String.replace("_", "-")
      end)

    case Enum.max_by(known, &String.jaro_distance(name, &1), fn -> nil end) do
      nil ->
        ""

      match ->
        if String.jaro_distance(name, match) >= 0.82, do: " (did you mean --#{match}?)", else: ""
    end
  end

  defp suggestion(_flag, _switches), do: ""

  defp host(parsed, inference, config) do
    %{
      state_dir: state_dir(config),
      model_source: model_source(parsed, inference, config),
      local_model: nil,
      continue: Keyword.get(parsed, :continue, false),
      project_mcp_trusted: project_mcp_trusted?(parsed),
      permission_mode: parsed[:permission_mode] || get_in_config(config, ["permissions", "mode"]),
      sandbox: parsed[:sandbox],
      mouse: mouse(parsed, config)
    }
  end

  defp model_source(parsed, inference, config) do
    cond do
      parsed[:model] -> :flag
      env("LMX_MODEL") -> :env
      inference[:ixway] -> :ixway
      Config.direct_model(config) -> :config
      true -> :fallback
    end
  end

  @doc """
  Where personal state lives for `config`: `LMX_HOME`, else the config
  file's directory, else `nil` (`--config none`). See the module
  documentation.
  """
  @spec state_dir(config :: Config.t() | nil) :: Path.t() | nil
  def state_dir(config) do
    case env("LMX_HOME") do
      home when is_binary(home) ->
        Path.expand(home)

      _unset ->
        case Config.path(config) do
          nil -> nil
          path -> Path.dirname(path)
        end
    end
  end

  # `--project-mcp` and `LMX_PROJECT_MCP=1` trust the repository's servers
  # for this run, without asking; the config file cannot, because trusting a
  # repository you have not looked at is a decision about that repository.
  defp project_mcp_trusted?(parsed) do
    parsed[:project_mcp] == true or
      System.get_env("LMX_PROJECT_MCP") in ["1", "true", "yes"]
  end

  defp get_in_config(config, [section, key]) do
    case Config.get(config, section) do
      %{} = fields -> Map.get(fields, key)
      _absent -> nil
    end
  end

  @doc "Resolved host limits, captured once with configuration and environment precedence."
  @spec limits(options :: t()) :: keyword()
  def limits(%__MODULE__{config: nil}), do: []
  def limits(%__MODULE__{config: config}), do: config.limits

  @doc "Whether web tools came only from the CLI's credential-backed default."
  @spec automatic_web?(options :: t()) :: boolean()
  def automatic_web?(%__MODULE__{given: given, config: config}) do
    not Keyword.has_key?(given, :web_search) and
      not Keyword.has_key?(given, :web_fetch) and
      is_nil(env("LMX_WEB_SEARCH")) and
      is_nil(System.get_env("LMX_WEB_FETCH")) and
      is_nil(Config.get(config, "web_search")) and
      is_nil(Config.get(config, "web_fetch"))
  end

  defp config_sessions_dir(config) do
    case Config.get(config, "sessions_dir") do
      nil -> default_sessions_dir()
      path -> Path.expand(path)
    end
  end

  defp web_search(parsed, config) do
    selected =
      parsed[:web_search] || env("LMX_WEB_SEARCH") || Config.get(config, "web_search")

    resolve_web_search(selected, config)
  end

  defp resolve_web_search(nil, config) do
    case System.get_env("BRAVE_SEARCH_API_KEY") ||
           Config.web_search_api_key(config, "brave") do
      key when is_binary(key) and key != "" -> {:ok, "brave"}
      _missing -> {:ok, nil}
    end
  end

  defp resolve_web_search(backend, _config) do
    case String.downcase(backend) do
      "brave" -> {:ok, "brave"}
      "none" -> {:ok, nil}
      _other -> {:error, unsupported_web_search(backend)}
    end
  end

  defp unsupported_web_search(backend),
    do:
      "unsupported web-search backend #{inspect(backend)}; supported backend: brave (use none to disable)"

  # A configured search key now equips the paired, guarded page reader for the
  # default CLI research workflow. Explicit flag, environment and file choices
  # still win independently, so an operator can keep search without fetch.
  #
  # On by default, and a trade rather than a free win. Capturing the mouse takes
  # the terminal's own text selection with it, so drag-to-select stops working;
  # what it buys is a wheel that scrolls the transcript, where uncaptured terminals
  # translate the wheel into arrow keys and the input box reads those as history.
  # A wheel that does the wrong thing is the worse default, and there are three
  # ways back: `--no-mouse`, `"mouse": false`, and Shift-drag. `Lemieux.TUI` itself
  # still defaults to `false` — this is `lmx` making a product choice, and a library
  # has no business taking an embedder's mouse unasked.
  defp mouse(parsed, config) do
    cond do
      is_boolean(parsed[:mouse]) -> parsed[:mouse]
      Config.get(config, "mouse") == false -> false
      true -> true
    end
  end

  # Three values, because there are three things to say and two of them used to
  # share `nil`: a path names the file to read; `nil` means nothing was said, so the
  # repository's own `.mcp.json` is used if it has one; `false` means say nothing to
  # the session at all, which `--no-project-mcp` and a resume both mean.
  #
  # On by default, because the alternative was a warning on every start telling you
  # to pass a flag naming a file the harness had already found. Opening an
  # unfamiliar repository does start its servers, which for a stdio server means
  # running its command, so the two ways off are deliberately cheap.
  defp mcp_config(parsed, config) do
    cond do
      parsed[:mcp_config] -> parsed[:mcp_config]
      is_boolean(parsed[:project_mcp]) -> project_mcp(parsed[:project_mcp])
      true -> ambient_project_mcp(System.get_env("LMX_PROJECT_MCP"), config)
    end
  end

  defp project_mcp(true), do: nil
  defp project_mcp(false), do: false

  # The ordinary precedence, and the environment earns its place here rather
  # than being a flag people repeat: "never start a repository's servers" is a
  # property of a shell — a CI job, a test suite, a machine somebody else's
  # checkout is about to be opened on — more often than of one command.
  defp ambient_project_mcp(nil, config),
    do: project_mcp(Config.get(config, "project_mcp") != false)

  defp ambient_project_mcp(value, _config) when value in ["1", "true", "yes"], do: nil
  defp ambient_project_mcp(_value, _config), do: false

  # On, because a session that cannot delegate tells somebody who asked for a
  # subagent that no such tool exists, and that answer is worse than the cost — which
  # is bounded by the definition's turn, time and budget limits and by
  # `Lemieux.CLI.Runtime`'s tree ceiling. That module owns the numbers; naming them
  # here is how this comment once stated four that were each wrong.
  #
  # The cost is measured: `eval/corpus/investigators-v1` ran parent-only against
  # parent-plus-delegate over thirty read-heavy cases on two models, both arms
  # solved 30/30, and delegation spent 4.6 to 5.1 times the tokens. So the default
  # buys an honest answer to "use subagents", not better answers to ordinary
  # questions. What that finding does not justify is leaving it off:
  # `Lemieux.Subagent.Delegate` tells the model the measured cost and when the tool
  # is not worth it. A resume is unaffected — `Lemieux.CLI.Runtime` reads the typed
  # flag rather than this value.
  defp delegate(parsed, config) do
    case parsed[:delegate] do
      flag when is_boolean(flag) -> flag
      nil -> ambient_delegate(System.get_env("LMX_DELEGATE"), config)
    end
  end

  defp ambient_delegate(nil, config), do: Config.get(config, "delegate") != false
  defp ambient_delegate(value, _config) when value in ["1", "true", "yes"], do: true
  defp ambient_delegate(_value, _config), do: false

  defp web_fetch(parsed, config, web_search) do
    case parsed[:web_fetch] do
      nil -> ambient_web_fetch(System.get_env("LMX_WEB_FETCH"), config, web_search)
      flag when is_boolean(flag) -> {:ok, flag}
    end
  end

  defp ambient_web_fetch(nil, config, web_search) do
    case Config.get(config, "web_fetch") do
      nil -> {:ok, web_search != nil}
      selected -> {:ok, selected}
    end
  end

  defp ambient_web_fetch(value, _config, _search) when value in ["1", "true", "yes"],
    do: {:ok, true}

  defp ambient_web_fetch(value, _config, _search) when value in ["", "0", "false", "no"],
    do: {:ok, false}

  defp ambient_web_fetch(value, _config, _search),
    do: {:error, "LMX_WEB_FETCH must be 1 or 0, not #{inspect(value)}"}

  # Config names first — they are the persistent form of `--extension` — then
  # the flags, walked through `parsed` rather than per switch so `--extension`
  # and `--extension-dir` keep the order they were typed in relative to each
  # other: `Lemieux.Harness.assemble/2` applies in list order, and order is
  # what an extension that wraps another's tool depends on.
  defp extensions(parsed, config) do
    if Keyword.get(parsed, :user_extensions, true),
      do: selected_extensions(parsed, config),
      else: {:ok, []}
  end

  defp selected_extensions(parsed, config) do
    typed =
      Enum.flat_map(parsed, fn
        {:extension, name} -> [{:name, name}]
        {:extension_dir, path} -> [{:dir, path}]
        _other -> []
      end)

    case Enum.find(typed, fn {tag, value} ->
           tag == :name and not Extensions.valid_name?(value)
         end) do
      nil ->
        configured = config |> Config.get("extensions", []) |> Enum.map(&{:name, &1})
        {:ok, configured ++ typed}

      {:name, name} ->
        {:error,
         "--extension #{inspect(name)} is not an extension name: " <>
           Extensions.name_rule(Extensions.default_root())}
    end
  end

  # `--oauth-client-id ISSUER=ID`, repeatable. Some authorization servers offer no
  # automatic registration at all — GitHub's does not — so the only way in is an
  # OAuth application somebody made by hand. The issuer is on the left because a
  # client id belongs to exactly one authorization server.
  defp oauth_clients(parsed) do
    parsed
    |> Keyword.get_values(:oauth_client_id)
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [issuer, id] when issuer != "" and id != "" ->
          {:cont, {:ok, Map.put(acc, issuer, %{"client_id" => id})}}

        _otherwise ->
          {:halt,
           {:error,
            "--oauth-client-id wants ISSUER=CLIENT_ID, for example " <>
              "--oauth-client-id https://github.com/login/oauth=YOUR_CLIENT_ID"}}
      end
    end)
  end

  @doc "Returns a configured model default, or the caller's specialized fallback."
  @spec inference_default(fallback :: String.t()) :: String.t()
  def inference_default(fallback) do
    case parse([]) do
      {:ok, options} ->
        if options.ixway || env("LMX_MODEL") || Config.direct_model(options.config),
          do: options.model,
          else: fallback

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  @doc """
  The model used when nothing says otherwise: the first row of
  `Lemieux.CLI.Models.recommended/0`.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  The value of the environment variable `name`, or `nil` when it is unset or
  blank; see "An empty variable is an unset one" in the module documentation.

  Used for `LMX_MODEL`, `LMX_WEB_SEARCH`, `LMX_ROUTER`, `LMX_BASE_URL`,
  `LMX_IXWAY_URL`, `LMX_CONFIG`, `LMX_HOME`, `LMX_SESSIONS_DIR`,
  `LMX_CREDENTIALS`, `LMX_OAUTH_CALLBACK_PORT`, `LMX_EXTENSIONS_DIR`,
  `LMX_MAX_TURNS`, `LMX_MAX_REQUESTS` and `LMX_MAX_COST_USD` — here, in
  `Lemieux.CLI.Config`, `Lemieux.CLI.ExtensionExperience`,
  `Lemieux.CLI.Extensions`, `Lemieux.CLI.Limits` and
  `Lemieux.CLI.Diagnostics`; a module reading one of them with
  `System.get_env/1` disagrees with the rest about a blank value. A blank
  `LMX_SESSIONS_DIR` was the working directory: transcripts written into
  whatever repository `lmx` was opened in.
  """
  @spec env(name :: String.t()) :: String.t() | nil
  def env(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end
  end

  @doc """
  Where transcripts live when nothing says otherwise.
  """
  @spec default_sessions_dir() :: Path.t()
  def default_sessions_dir do
    env("LMX_SESSIONS_DIR") || Path.expand("~/.lmx/sessions")
  end

  @doc """
  Where MCP credentials live when nothing says otherwise:
  `~/.lmx/mcp-credentials.json`, or `LMX_CREDENTIALS` (`Lemieux.CLI.OAuth`).
  """
  @spec default_credentials() :: Path.t()
  def default_credentials do
    env("LMX_CREDENTIALS") || OAuth.default_store()
  end

  @doc """
  The loopback port the OAuth callback is received on.

  Fixed rather than ephemeral — `Lemieux.MCP.Auth.new/1` says why — and
  therefore worth being able to move when something else on the machine already
  has 8642.
  """
  @spec default_callback_port() :: pos_integer()
  def default_callback_port do
    case env("LMX_OAUTH_CALLBACK_PORT") do
      nil -> 8642
      value -> value |> String.trim() |> String.to_integer()
    end
  end

  @log_levels ~w(emergency alert critical error warning notice info debug none)a
  @log_level_strings Map.new(@log_levels, &{Atom.to_string(&1), &1})

  @doc """
  The log level `lmx` runs at, from `$LMX_LOG_LEVEL`.

  Defaults to `:error`, which is lower than a library's default on purpose.
  `req_llm` logs a warning containing the inspected error struct — twenty HTTP
  headers and a stack trace — for every failed request, and lemieux reports
  the same failure itself, in a sentence, on stderr. At the default level a
  person sees the sentence; `LMX_LOG_LEVEL=debug` gives back everything the
  libraries have to say when the sentence is not enough.
  """
  @spec log_level() :: Logger.level() | :none
  def log_level do
    case System.get_env("LMX_LOG_LEVEL") do
      nil -> :error
      name -> Map.get(@log_level_strings, String.downcase(name), :error)
    end
  end
end
