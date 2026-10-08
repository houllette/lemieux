defmodule Lemieux.CLI.Help do
  @moduledoc """
  `lmx --help`, `lmx help` and `lmx help TOPIC`.

  `lmx --help` is the first documentation most people read, and it used to
  be the whole manual: 172 lines that opened with the harness-learning
  research commands and a feedback option block, so a newcomer's first
  screen of a coding agent was about curating benchmark cases, and it ended
  without saying where the guides, the bug tracker or a place to ask were.
  It is now the everyday commands, the options most runs use and where to
  read more; everything else is a topic:

    * `lmx help options` — the old full text: every flag but the MCP OAuth
      and research ones, which it points to;
    * `lmx help learning` — `feedback`, `corpus`, `harness` and the
      builder's flags, the experimental research toolchain;
    * `lmx help mcp` — MCP servers, including OAuth authorization;
    * one topic per task — permissions, models, sessions and the rest —
      written for someone who already knows what they are trying to do.

  `lmx COMMAND --help` prints the topic for commands that have one.

  The model table is rendered from `Lemieux.CLI.Models.recommended/0`, and
  the example models in the usage are looked up in it, so the help and the
  code cannot recommend different models.
  """

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.Environment.Sandbox

  @topics ~w(config models permissions sandbox mcp plugins skills extensions sessions environment
             options learning desktop update)

  @links [
    {"Docs", "https://hexdocs.pm/lemieux"},
    {"Issues", "https://github.com/houllette/lemieux/issues"},
    {"Questions", "https://github.com/houllette/lemieux/discussions"}
  ]

  @doc "The topic names `lmx help TOPIC` accepts."
  @spec topics() :: [String.t()]
  def topics, do: @topics

  @doc """
  Where to read more and where to ask, as `{label, url}` pairs: the end of
  `lmx --help` and of the terminal UI's `/help`.
  """
  @spec links() :: [{String.t(), String.t()}]
  def links, do: @links

  @doc "The text for `topic`, or a sentence naming the topics there are."
  @spec topic(topic :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def topic(topic) when topic in @topics, do: {:ok, text(topic)}

  def topic(topic),
    do: {:error, "no help topic #{inspect(topic)}; topics: #{Enum.join(@topics, ", ")}"}

  @doc "The topic a command's `--help` prints, when it has one of its own."
  @spec command(command :: String.t()) :: {:ok, String.t()} | :none
  def command("plugin"), do: topic("plugins")
  def command("extension"), do: topic("extensions")
  def command("mcp"), do: topic("mcp")
  def command("skills"), do: topic("skills")
  def command("desktop"), do: topic("desktop")
  def command("update"), do: topic("update")
  def command(command) when command in ~w(log fork request), do: topic("sessions")
  def command(command) when command in ~w(feedback corpus harness), do: topic("learning")
  def command(_command), do: :none

  @doc """
  The lines the usage ends with: the topics, then `links/0`.
  """
  @spec footer() :: String.t()
  def footer do
    """
    Topics: lmx help config | models | permissions | sandbox | mcp | plugins |
            skills | extensions | sessions | environment | options (more flags) |
            learning (feedback, corpus and harness commands) | desktop

    #{Enum.map_join(@links, "\n", fn {label, url} -> String.pad_trailing(label <> ":", 11) <> url end)}\
    """
  end

  @doc """
  `lmx --help`: the commands and options most runs need, and where the rest is.

  About fifty lines: the draft it started from had thirty-eight, and the
  routing flags, the Claude Code sentence and the links were each kept on
  purpose. `lmx request` and the session-name sentence are in `lmx help
  sessions`.
  """
  @spec usage() :: String.t()
  def usage do
    """
    lmx — an open-source terminal coding agent, built on Lemieux

    Usage:
      lmx [options]                 Open the full-screen agent (also: lmx tui)
      lmx run PROMPT [options]      Answer one prompt and exit (stdin: lmx run -)
      lmx log SESSION               Print a stored conversation
      lmx fork SESSION [CUT]        Copy a conversation to branch from it
      lmx explain [options]         Show what a session would start with (JSON)
      lmx mcp list|trust|import     Manage MCP servers (lmx help mcp)
      lmx plugin install|list|remove
                                    Manage Claude Code-compatible plugins
      lmx extension new|list        Write or list your own Elixir extensions
      lmx skills [--json]           List the skills a session finds, and from where
      lmx desktop install|uninstall Linux app launcher entry (lmx help desktop)
      lmx update [--check]          Install a newer release (lmx help update)
      lmx help [TOPIC]              This message, or one topic (list below)

    Common options:
      -m, --model PROVIDER:MODEL    #{model_option()}
      -c, --continue                Resume the newest session from this directory
          --resume SESSION          Resume a session by id or name (wayne-gretzky)
      -C, --cwd DIR                 Work in DIR instead of the current directory
          --permission-mode MODE    ask, accept_edits, auto, full_auto, read_only
                                    Default: off, so tools run without asking
                                    (lmx help permissions)
          --sandbox                 Run commands in a sandbox (lmx help sandbox)
          --max-cost-usd N          Stop before spending more than N dollars
          --max-turns N             Model turns per prompt (default 400)
          --output-format F         lmx run only: text | json | stream-json
          --config PATH|none        Settings file (default ~/.lmx/config.json)
          --router MODE             Routing: direct, ixway or a route (LMX_ROUTER)
          --ixway URL               Use Ixway as the sole inference pipeline
                                    (instance origin; LMX_IXWAY_URL and
                                    IXWAY_API_KEY). Models: ixway:ID
          --base-url URL            Route model API calls through this provider-
                                    compatible gateway (or set $LMX_BASE_URL)
      -h, --help                    Show this message
      -v, --version                 Show the version

    #{claude_code()}

    Exit status (lmx run): 0 answered, 1 other, 2 usage, 3 credentials,
    4 limit reached, 5 cancelled, 6 provider error.

    #{footer()}
    """
  end

  # The anthropic and openai rows of the recommendation table, whatever order
  # it is in: the examples name models the code would actually start on.
  # Wrapped rather than laid out by hand, so a longer model name cannot push
  # the column past 80; two lines for today's names, with no "e.g." in
  # front, which pushed them onto a third.
  defp model_option do
    recommended = Models.recommended()

    examples =
      Enum.flat_map(~w(anthropic openai), fn provider ->
        case Enum.find(recommended, &(&1.provider == provider)) do
          nil -> []
          row -> [row.model <> ","]
        end
      end)

    (examples ++ ["or ollama:MODEL (lmx help models)"])
    |> Enum.join(" ")
    |> wrap(48)
    |> Enum.join("\n" <> String.duplicate(" ", 32))
  end

  defp wrap(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | lines] ->
        if String.length(line) + 1 + String.length(word) <= width,
          do: [line <> " " <> word | lines],
          else: [word, line | lines]
    end)
    |> Enum.reverse()
  end

  # What a Claude Code user can bring, said no wider than it is: the
  # configuration guide's compatibility table has the fields and events that
  # are not supported yet, and a sentence here cannot keep up with them.
  defp claude_code do
    """
    lmx reads Claude Code skills, slash commands, plugins, MCP configuration and
    hook settings; known gaps: #{docs_url("configuration.html")}\
    """
  end

  defp docs_url(page), do: "https://hexdocs.pm/lemieux/" <> page

  # The sandbox's own default list, under `~`, rather than a copy of it:
  # this topic said "(~/.ssh, ~/.aws, ~/.lmx, …) hidden" while the list
  # grew, and "…" read as "every credential directory", which it never was.
  # A path added to `Lemieux.Environment.Sandbox`'s list is named here the
  # moment it is hidden.
  defp hidden_paths do
    "~"
    |> Sandbox.default_hidden()
    |> Enum.join(", ")
    |> wrap(70)
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp text("config") do
    """
    Usage: ~/.lmx/config.json (or --config PATH; --config none reads nothing)

    Settings a new session starts from; flags and LMX_* variables win.
    A field this build does not know is named and ignored, unless it is a
    likely misspelling of a routing field (model, providers, base_url,
    ixway), which is refused. A wrong value names its field and what it
    takes. An empty api_key is a placeholder: named at startup, ignored.

      model                 the model new sessions start with
      providers.NAME        api_key, model, effort for one provider
      scout_model           the model the repository scout runs on
      permissions           see lmx help permissions (off by default)
      sandbox               see lmx help sandbox (off by default)
      hooks                 command hooks, lmx's format or Claude Code's
      scrub_credentials     false passes variables named *KEY*, *TOKEN*,
                            *SECRET*, *PASSWORD* or *PASSWD* to commands,
                            hooks and MCP servers (default true)
      credential_allowlist  names (or NAME_* patterns) passed through anyway
      mcp_servers           your own MCP servers, as in .mcp.json
      mcp_discovery         auto (default), on or off
      plugin_dirs, marketplaces, plugins
                            saved plugin selections (lmx help plugins)
      skills                {"omarchy": false} stops reading Omarchy's skills;
                            {"disabled": ["NAME"]} leaves skills out by name
      extensions            your extensions by name (lmx help extensions)
      extension_options     NAME: {options} for each extension
      verify                false, or {command, max_continuations, timeout_ms}
      continuation          false, or {max_continuations,
                            max_output_continuations}: how often a prompt
                            left unfinished or cut off is sent back to work;
                            {completion_check: true} also asks a finished
                            one to check the task as written, once
      input_modalities      ["text", "image", "pdf"] for a model the catalog
                            does not know, so tools can show it attachments
      auto_compaction       false: a session never compacts on its own
      theme, themes, keys   the terminal UI's colours and key bindings
      mouse                 false gives the mouse back to the terminal
      notifications         false stops the terminal UI ringing when a turn
                            ends or needs you (default true)
      disabled_extensions   shipped extensions to leave out: planning, verify,
                            continuation, budget, search, apply_patch,
                            checkpoints, environment_context, mcp_discovery,
                            elixir, delegation, …
    """
  end

  defp text("models") do
    rows =
      Enum.map_join(Models.recommended(), "\n", fn row ->
        "  #{String.pad_trailing(row.label, 18)} #{String.pad_trailing(row.env || "", 22)} #{row.model}"
      end)

    """
    Usage: lmx --model PROVIDER:MODEL (or LMX_MODEL, or "model" in the config)

    When nothing names a model, lmx starts on the one you last chose, if it
    can still be reached: the model the terminal UI last started on because
    you named it (--model, LMX_MODEL, the config file or an Ixway route, or
    /model or /provider after a start that failed). A model chosen in a
    running session, or for lmx run, is not remembered. Else lmx starts on
    the first provider below whose key is set; else on a model the local
    Ollama serves that can call tools; else on the first row, and the
    terminal UI offers to set a key up. --config none skips all of that and
    uses the first row.

    #{rows}

    Ollama's default window can be as small as 4,096 tokens, and it drops
    what does not fit, the task first: set OLLAMA_CONTEXT_LENGTH to 32768 or
    more (65536 recommended) for the Ollama server; `ollama ps` shows it.
    """
  end

  defp text("permissions") do
    """
    Usage: lmx --permission-mode MODE, or "permissions": {"mode": MODE}

    Off unless a mode is set. When on, tools that change things ask first:

      ask            ask before edits, commands and anything else that writes
      accept_edits   file edits in the working directory run unasked
      auto           with --sandbox (lmx help sandbox), edits and commands run
                     unasked; without it, like accept_edits. MCP, web and eval
                     tools ask either way
      full_auto      nothing asks; deny rules still apply
      read_only      tools that change things are refused

    "allow", "deny" and "ask" take Claude Code-style rules: "Bash(npm test:*)",
    "Edit(src/**)", "Read", "mcp__server__tool". Deny always wins. "Always
    allow" answers are remembered per repository under ~/.lmx/permissions.
    In lmx run nobody can answer, so a call that would ask is refused
    ("non_interactive": "allow" changes that). In the terminal UI, Shift-Tab
    steps through the modes once permissions are on.
    """
  end

  defp text("sandbox") do
    """
    Usage: lmx --sandbox, or "sandbox": true | {"enabled": true, ...}

    Runs commands inside macOS Seatbelt or Linux bubblewrap: writes only to
    the working directory, temporary directories and tool caches, and no
    network beyond loopback. Hidden from commands and file tools alike,
    if they exist when the sandbox starts:

    #{hidden_paths()}
      the paths in the config's "hidden"
      wherever this run keeps its config, state, sessions and MCP tokens
      (--config, LMX_HOME, --sessions-dir, --credentials); of those, nothing
      that is or holds the working directory, home or a temporary directory

    Keys: backend (auto|seatbelt|bubblewrap), network, localhost, writable,
    hidden. A sandbox that was asked for and cannot start stops lmx rather
    than running without it. The eval node, MCP servers, hooks and web
    tools run outside it.
    """
  end

  defp text("mcp") do
    """
    Usage: lmx mcp list | lmx mcp trust [--yes] | lmx mcp untrust
           lmx mcp import claude|codex

    MCP servers come from four places:

      --mcp-config FILE    started as named
      "mcp_servers"        your own, in the config file
      .mcp.json            the repository's, only once you trust them: the
                           terminal UI asks; lmx mcp trust --yes records it;
                           --project-mcp trusts them for one run;
                           --no-project-mcp never starts them
      plugins              a selected plugin's, named plugin_PLUGIN_SERVER;
                           selecting the plugin trusts them (lmx help plugins)

    A server of your own replaces the repository's server of the same name:
    that one is neither started nor asked about, and lmx mcp list marks it.
    A repository's configuration may not expand variables that look secret
    (*KEY*, *TOKEN*, *SECRET*, *PASSWORD*, *PASSWD*) unless you approved them
    when trusting it.
    lmx mcp import copies Claude Code's (~/.claude.json) or Codex's
    (~/.codex/config.toml) servers into "mcp_servers".

    An MCP server that wants OAuth is authorized in your browser, once:

          --credentials F  Where MCP tokens are kept, mode 0600 (or
                           $LMX_CREDENTIALS); default
                           #{Options.default_credentials()}
          --oauth-callback-port N
                           Loopback port the browser is redirected back to
                           (default #{Options.default_callback_port()}, or $LMX_OAUTH_CALLBACK_PORT).
                           Fixed rather than random so it can be forwarded:
                           ssh -L N:localhost:N devbox
          --oauth-client-id ISSUER=ID
                           A client id you registered by hand, for an
                           authorization server that offers no automatic
                           registration. Repeatable. The error you get
                           without one names the issuer to use here.
    """
  end

  defp text("plugins") do
    """
    Usage: lmx plugin install PATH|GIT-URL | lmx plugin list
           lmx plugin remove NAME|PATH

    A Claude Code-compatible plugin brings skills, commands, agents, hooks and
    MCP servers. Installing one saves it in "plugin_dirs", which is the
    decision to trust it: its hooks run and its servers start in every
    session. A Git URL is cloned into ~/.lmx/plugins/NAME. For one session
    only, use --plugin-dir D, or --marketplace S with --plugin N@M. Not
    every Claude Code plugin feature is supported yet; the compatibility
    table in the configuration guide (#{docs_url("configuration.html")})
    lists the gaps.
    """
  end

  defp text("skills") do
    """
    Usage: lmx skills [--json] [--skill-dir D] [--plugin-dir D] [--plugin N@M]

    Lists every Agent Skill and legacy command a session started here finds:
    where it came from, whether it is enabled, its path (and real path when a
    link points elsewhere), and the copies of its name it hides. --json is
    for scripts. Later sources win a name clash:

      bundled < Omarchy < ~/.codex/skills < ~/.agents/skills
      < ~/.claude/skills < ~/.lmx/skills < the repository's .agents/skills
      and .claude/skills, root first < --skill-dir

    Omarchy's skills are read in place, from default/agents/skills under
    $OMARCHY_PATH, else /usr/share/omarchy, else ~/.local/share/omarchy.
    In the config file, "skills": {"omarchy": false} stops that, and
    "disabled": ["NAME", "plugin:NAME"] leaves skills out wherever they come
    from. The skill tool also loads the files beside a skill (its
    references), which the read tool cannot reach.
    """
  end

  defp text("extensions") do
    """
    Usage: lmx extension new NAME [--dir D] | lmx extension list

    An extension is Elixir code that shapes a session. lmx extension new
    writes a one-file script extension under ~/.lmx/extensions/NAME; select it
    with --extension NAME or "extensions": ["NAME"]. Options for it live in
    "extension_options": {"NAME": {...}}, so rebuilding it keeps them. A Mix
    project built with mix lmx.extension.build is the larger form; MCP
    servers and command hooks need no Elixir at all.

    An extension may also register a model route (routes/1, see
    Lemieux.Extension.Routes): its models are NAME:ID beside the direct
    providers', /provider NAME switches to it, and --router NAME starts on
    its advertised default. A route never falls back to a direct key.
    """
  end

  defp text("sessions") do
    """
    Usage: lmx --resume SESSION | lmx -c | lmx log SESSION | lmx fork SESSION

    Every session is a transcript in ~/.lmx/sessions (or --sessions-dir).
    SESSION is its id or its name (wayne-gretzky). -c/--continue resumes the
    newest session that ran in this directory. /resume in the terminal UI
    lists sessions by last activity. A transcript is written by one lmx at
    a time; opening one that is already open says where.

      lmx log SESSION [--jsonl]    print it, or every entry as JSON lines
      lmx request SESSION ID       print one recorded model request
      lmx fork SESSION [CUT]       copy it, printing the new id; CUT is
                                   --at ID, --at-seq N or --at-turn N
                                   (--unsafe permits an unfinished turn)
    """
  end

  defp text("environment") do
    """
    Usage: variables lmx reads

      LMX_MODEL, LMX_ROUTER, LMX_BASE_URL, LMX_IXWAY_URL
      LMX_CONFIG            a config path, or none
      LMX_HOME              where remembered state lives (default ~/.lmx)
      LMX_SESSIONS_DIR      where transcripts live
      LMX_EXTENSIONS_DIR    where --extension NAME looks (default
                            ~/.lmx/extensions)
      LMX_MAX_TURNS, LMX_MAX_REQUESTS, LMX_MAX_COST_USD
      LMX_PROJECT_MCP       1 trusts, 0 never starts, the repository's .mcp.json
      LMX_DELEGATE, LMX_WEB_SEARCH, LMX_WEB_FETCH, LMX_CREDENTIALS
      LMX_OAUTH_CALLBACK_PORT
      OMARCHY_PATH          where Omarchy is installed; its skills are read
                            from there (lmx help skills)
      LMX_CHECK_UPDATES     0 stops the installed lmx checking for a new
                            version on its own (at start, after /new and
                            /resume, and hourly); lmx update and /update
                            still check
      LMX_AUTO_UPDATE       0 stops the installed lmx installing updates on its
                            own, which it does only once their Ed25519
                            signature verifies, and not on Windows or with
                            extensions selected; lmx update and /update
                            still install
      LMX_LOG_LEVEL         log lines go to logs/lmx.log in the state
                            directory (LMX_HOME, else beside the config file:
                            ~/.lmx/logs/lmx.log; none for --config none),
                            errors only; setting this (debug, info, warning,
                            error) also prints them on standard error, at
                            that level, which the terminal UI does only when
                            standard error is not the terminal (2> FILE),
                            and on Windows not at all
    """
  end

  defp text("update") do
    """
    Usage: lmx update [--check]

    Checks the project's GitHub releases for a newer stable lmx and installs
    it, after the checks the terminal UI's /update makes: the release's
    update manifest must carry a valid Ed25519 signature from the key built
    into this lmx, and the archive must match it. Nothing from the archive
    runs while it installs. --check only says whether one is available.

    The new version runs the next time lmx starts. A terminal UI that is open
    keeps running the version it started on until you restart it; it is never
    stopped from here, and the two never install at once.

    No session, model key or personal config file is needed, so lmx update
    works while a mistake in the config file keeps the screen from opening.

    Only an lmx that install.sh or install.py installed can update itself; an
    archive unpacked by hand, and the Windows build, are updated by
    downloading the new archive. From a source checkout, mix lmx update
    fast-forwards the checkout from its Git upstream instead, as its /update
    does. Running the installer again also upgrades its own installation;
    --replace is only for installing over an lmx it did not write.

    Exit status: 0 up to date, installed, or --check reported; 1 the check or
    the installation failed; 2 usage.
    """
  end

  defp text("options") do
    """
    Usage: lmx [COMMAND] [options] — every option

    Run options:
          --output-format F
                           text (default: only the final answer on stdout),
                           json (one result object) or stream-json (one event
                           per line, ending with the result)
          --bare           Leave out the workspace: instructions, memory,
                           skills and plugins (--system implies it)
      -                    Read the prompt, or this part of it, from stdin;
                           with no prompt at all, piped input is the prompt
                           Exit status: 0 answered, 2 usage, 3 credentials,
                           4 a limit, 5 cancelled, 6 provider, 1 other

    Fork cuts:
          --at ID          Cut after a durable entry id
          --at-seq N       Cut after transcript sequence N
          --at-turn N      Cut after completed assistant turn N
          --unsafe         Permit a cut inside an unfinished turn

    Options:
      -C, --cwd DIR        Run as if started in DIR (its tools, instructions
                           and .mcp.json); other paths stay relative to here
      -c, --continue       Resume the newest session that ran here (TUI or run)
          --permission-mode MODE
                           Ask before tools change things: ask, accept_edits,
                           auto, full_auto or read_only (default: off; see
                           lmx help permissions)
          --sandbox        Run commands in Seatbelt/bubblewrap (lmx help sandbox)
          --max-turns N    Maximum model turns per prompt (default 400)
          --max-requests N Maximum direct provider requests across the session
          --max-cost-usd N Dollar ceiling; unknown cost stops before execution
                           Limits also accept LMX_MAX_TURNS, LMX_MAX_REQUESTS,
                           LMX_MAX_COST_USD and personal config settings.
      -m, --model SPEC     Model to use (or $LMX_MODEL; without one, the model
                           the terminal UI last started on because you named
                           it, else one your keys or a local Ollama can
                           reach; see lmx help models)
          --config PATH    Personal JSON config (default ~/.lmx/config.json;
                           LMX_CONFIG or --config none to disable)
          --router MODE    Routing: direct, ixway or a registered route's name
                           (LMX_ROUTER)
          --ixway URL      Use Ixway as the sole inference pipeline (instance origin;
                           LMX_IXWAY_URL and IXWAY_API_KEY). Models: ixway:ID
          --base-url URL   Route model API calls through this provider-compatible
                           gateway (or set $LMX_BASE_URL)
          --system TEXT    System prompt
          --resume SESSION Continue a stored session, by id or by its name
                           (e.g. wayne-gretzky, shown when it started)
          --prompt TEXT    Terminal UI only: send TEXT as the first message
                           once the session is up (--prompt=TEXT when it
                           starts with a dash); lmx run takes its prompt as
                           an argument
          --mcp-config F   Attach the MCP servers named in a JSON file, instead
                           of the repository's own .mcp.json
          --project-mcp    Trust the repository's .mcp.json for this run
                           (otherwise its servers start once you trust them:
                           the TUI asks, or lmx mcp trust --yes)
          --no-project-mcp Do not start the repository's .mcp.json (also
                           $LMX_PROJECT_MCP=0, or "project_mcp": false)
          --hooks F        Run command hooks from F: lmx's version-1 hooks
                           file, or a Claude Code settings file's "hooks".
                           Some Claude Code hook fields are not supported
                           yet; the hooks guide lists them:
                           #{docs_url("hooks.html")}
          --extension N    Load your own extension N from
                           #{Extensions.default_root()}
                           (repeatable; "extensions": ["N"] in the config file
                           does the same every time). Built there by
                           mix lmx.extension.build in a project of yours.
          --extension-dir D
                           Load the extension in directory D (repeatable). The
                           only way a directory inside a checkout is loaded:
                           like --hooks, it takes your say-so, never the
                           repository's.
          --no-user-extensions
                           Ignore configured and command-line user extensions;
                           host policy and required resume checks remain active.
          --explain-against F
                           With explain, compare against a saved explanation.
          --skill-dir D    Add Agent Skills from D (repeatable)
          --plugin-dir D   Add an installed local plugin (repeatable)
          --marketplace S  Read a local, Git/GitHub, or direct-URL marketplace
                           catalog (repeatable)
          --plugin N@M     Fetch and enable plugin N from marketplace M
                           (repeatable)
          --context-window N
                           How many tokens this model's window holds, for
                           planning compaction; for Ollama, the server's own
                           window (OLLAMA_CONTEXT_LENGTH) decides what the
                           model sees
          --web-search B   Web-search backend: brave, or none to turn it off
                           (also $LMX_WEB_SEARCH, or "web_search" in the
                           config). When none of those says, it is on whenever
                           a Brave key is set: $BRAVE_SEARCH_API_KEY or
                           config.json's web_search_providers.brave.api_key.
          --web-fetch      Add the web_fetch tool: read one public http(s)
                           page as bounded text. On by default whenever web
                           search is on, off otherwise; --no-web-fetch or
                           $LMX_WEB_FETCH=0 turns it off, $LMX_WEB_FETCH=1 on.
                           Loopback, private and link-local addresses are
                           refused.
          --sessions-dir   Where transcripts are written (or $LMX_SESSIONS_DIR);
                           default #{Options.default_sessions_dir()}
          --elixir         Replace the file tools with the Elixir evaluation
                           tool, on a separate BEAM node. Explicit MCP tools
                           and delegation still compose. Off by default: it is
                           a wider bargain.
          --no-delegate    Withhold the bounded read-only repository scout,
                           which is supplied by default (also
                           $LMX_DELEGATE=0, or "delegate": false). The scout
                           uses the selected model and may fan out to three
                           children, each capped, under a cumulative ceiling
                           for the whole tree.
          --no-mouse       Give the mouse back to the terminal, so drag can
                           select and copy transcript text again. The cost is
                           that terminals then translate the wheel into arrow
                           keys, which walk input history instead of scrolling.
                           Captured by default; Shift-drag selects either way
                           (Option-drag in iTerm2, Fn-drag in Terminal.app),
                           as do Page Up, Page Down, shift-arrows and /copy.
      -h, --help           Show the short help (lmx help TOPIC for one topic)
      -v, --version        Show the version

    MCP OAuth (--credentials, --oauth-callback-port, --oauth-client-id):
    lmx help mcp. The builder and research flags (--build-ext, --quota,
    --extension-profile): lmx help learning.
    """
  end

  defp text("desktop") do
    """
    Usage: lmx desktop install [--exec PATH] [--directory DIR]
                               [--omarchy|--no-omarchy] [--force]
           lmx desktop uninstall | lmx desktop status

    Linux only, and only when you ask: installing or updating lmx never
    touches your desktop. install writes lemieux.desktop into
    $XDG_DATA_HOME/applications (default ~/.local/share/applications) and
    lmx's icon into icons/hicolor beside it, and runs nothing else.

      --exec PATH       the lmx the entry runs, as a full path (default: the
                        installer's launcher, else the lmx on PATH)
      --directory DIR   where it starts, passed as -C DIR (default: your home
                        directory; on Omarchy, ~/Work when it exists)
      --omarchy         open it with omarchy-launch-tui, app id
                        org.omarchy.lemieux (the default where that is on
                        PATH); --no-omarchy uses the desktop's terminal
      --force           replace a lemieux.desktop or icon lmx did not
                        write, or install as root

    uninstall removes only what install wrote, and never ~/.lmx. status
    shows the entry, what it runs and where, and whether Omarchy is here.
    lmx --prompt TEXT opens the terminal UI and sends TEXT first.
    Keybindings and menu entries: #{docs_url("desktop.html")}
    """
  end

  defp text("learning") do
    """
    Usage: lmx feedback | lmx corpus | lmx harness — harness learning

    Experimental. These commands serve the harness-learning toolchain:
    recording feedback about sessions, turning it into benchmark cases and
    applying tuned harnesses (#{docs_url("harness-learning.html")}).

      lmx feedback SESSION [options]
                                   Capture anchored feedback outside the transcript
      lmx feedback --mine SESSION  Let the model record improvement opportunities
                                   as feedback, without touching the transcript
      lmx feedback draft-case ID --source DIR --output DIR --prompt P --verifier CMD
                                   Freeze a fixture and verifier beside a feedback
                                   record as an unapproved benchmark case
      lmx corpus promote DRAFT_DIR MANIFEST --cluster ID [--tag T] [--allow PATH]
                                   Promote a reviewed draft into a corpus manifest
      lmx harness verify TYPE FILE Verify a harness-learning contract
      lmx harness materialize B A D Materialize bundle B using artifact dir A into D
      lmx harness export CAMPAIGN_DIR CANDIDATE_ID [--to PATH]
                                   Write a confirmed discovery candidate to
                                   .lmx/harness.json (prompt text only; tool
                                   descriptions apply from ~/.lmx/harness.json)

    Feedback options:
          --text TEXT      Feedback prose (otherwise read one line from stdin)
          --entry ID       Anchor to this entry (default: latest entry)
          --scope SCOPE    task, project, tenant, or global (default project)
          --standing-rule  Mark this as behavior that should continue to apply
          --feedback-dir D Dedicated feedback ledger directory
          --mine           Mine opportunities with the model instead of --text
          --model SPEC     Model for --mine (default: the ordinary CLI model)

    Builder and profile options (lmx and lmx run):
          --build-ext      Optional guided builder (TUI or run); priced route
                           or --quota required. Normal TUI: /create-extension
          --quota          Builder: bound requests for a quota subscription
                           (12 for zai_coding_plan:glm-5.3, otherwise 30)
          --extension-profile F
                           Use a tuned session extension's profile JSON
    """
  end
end
