# The suite runs on a contributor's machine, under whatever that machine has
# configured. Each step below removes one way a result could depend on it, and
# says which failure put it here. CI has none of these settings, which is why
# every one of them was found on somebody's laptop rather than in a red build.

# `req_llm` loads the checkout's `.env` as it starts, before this file runs,
# setting each variable that was not already set. Two steps below need to know
# what it set, so the file is read here the way req_llm reads it
# (`Dotenvy.source/1` starts from no variables), except that its `$(...)`
# commands are not run: req_llm has already run them once, and they may prompt
# (a password manager's `op read`). A value a command produced therefore reads
# as "" here. A file req_llm could not parse is one it loaded nothing from.
dotenv_path = Path.join(File.cwd!(), ".env")
no_commands = fn _command, _arguments, _options -> {"", 0} end

dotenv =
  with true <- File.regular?(dotenv_path),
       {:ok, values} <-
         Dotenvy.Parser.parse(File.read!(dotenv_path), %{}, sys_cmd_fn: no_commands) do
    values
  else
    _absent_or_unparsable -> %{}
  end

# Paid runs take two deliberate steps: selecting :live or :eval_live, and
# LEMIEUX_ALLOW_SPEND=1 set for the run, never in `.env`. `LemieuxTest.Spend`
# says why. `ExUnit.configuration/0` already holds the command line's filters
# when this file runs.
include = ExUnit.configuration()[:include] || []
spend_run? = LemieuxTest.Spend.run?(include)

case LemieuxTest.Spend.refusal(include, System.get_env("LEMIEUX_ALLOW_SPEND"), dotenv) do
  nil -> :ok
  refusal -> Mix.raise(refusal)
end

# python3 is a prerequisite of the ordinary suite, not an extra: the MCP client
# tests talk to fixture servers written in Python (test/fixtures/mcp_server.py)
# and several process tests wait on test/fixtures/wait_process.py. Without it
# 96 tests failed one by one, each in its own words; this says it once.
if System.find_executable("python3") == nil do
  Mix.raise("""
  python3 is required to run this suite, and it is not on PATH. The MCP tests \
  talk to fixture servers written in Python (test/fixtures/mcp_server.py), and \
  process tests wait on test/fixtures/wait_process.py.

  Install Python 3 (macOS: xcode-select --install; Debian or Ubuntu: \
  apt install python3) and run the suite again.
  """)
end

# Credentials must not change what the ordinary suite asserts, and must not
# reach it at all. A Brave key turns web search on by default
# (`Lemieux.CLI.Options`), which adds `web_search`, `web_fetch` and
# `research_check` to every tool catalog: a key kept in `.env` failed 22
# catalog tests that CI, which has none, passed (2026-09-29). An exported
# `IXWAY_API_KEY` overrides the key a configuration test writes. And a test
# selected by line (`mix test path:LINE`) runs even when its tag is excluded,
# because an include beats every exclude: a live test chosen that way would
# spend money on an exported key without either step above. Live tests also
# carry a `:skip` tag that a location does not beat (`LemieuxTest.Spend.skip/0`,
# which suite_isolation_test.exs holds every one of them to). So every variable
# req_llm reads a provider's key from is removed (`ReqLLM.Keys.env_var_name/1`
# for each provider it knows), and every other `*_API_KEY` with them: that
# covers the Brave, Ixway, Jev and Ollama keys Lemieux reads itself, and the
# usual provider keys under `mix test --no-start`, where req_llm's provider
# registry is still empty. Runs that select live tests keep them all.
#
# What `.env` injected is taken back too. A verbatim copy of `.env.example`
# failed 160 of 350 CLI tests: its empty `OPENAI_API_KEY=` deliberately
# disables a saved key, and its empty `LMX_WEB_SEARCH=` names no backend. Every
# variable that still holds exactly the file's value is removed; one a command
# produced cannot be compared and stays, unless it is a credential. This comes
# before the steps below set anything, so that a `.env` holding
# `LMX_CONFIG=none` cannot take back the value they set. And once is not
# enough: the suite restarts `:req_llm` when it resizes the provider pool
# (`Lemieux.ProviderPool`), and each start would load `.env` again, so loading
# is switched off for the rest of the run.
unless spend_run? do
  for {name, value} <- dotenv, System.get_env(name) == value, do: System.delete_env(name)

  credentials = Enum.map(ReqLLM.Providers.list(), &ReqLLM.Keys.env_var_name/1)

  for {name, _value} <- System.get_env(),
      name in credentials or String.ends_with?(name, "_API_KEY"),
      do: System.delete_env(name)

  Application.put_env(:req_llm, :load_dotenv, false)
end

# Personal CLI settings must never turn deterministic tests into paid network
# calls or make their defaults depend on the developer's home directory.
# Configuration tests select their own temporary files explicitly.
System.put_env("LMX_CONFIG", "none")

# For the same reason, one directory out: `lmx` starts a repository's own
# `.mcp.json` by default, and this suite runs inside whatever checkout it is in.
# A command test would otherwise reach for whatever server that checkout
# declares — a connection attempt at best, a spawned process for a stdio
# server — and the suite's behaviour would depend on the working tree it was
# run from. Tests that want the default exercise it explicitly.
System.put_env("LMX_PROJECT_MCP", "0")

# The same holds for every other `LMX_*` override, which the guides tell people
# to export (`LMX_MODEL`, `LMX_WEB_SEARCH=brave`) and which a checkout's `.env`
# sets before this file runs. Exported in a contributor's shell,
# `LMX_WEB_SEARCH=brave` failed 106 tests, `LMX_WEB_FETCH=1` 28,
# `LMX_DELEGATE=0` 16 and `LMX_MODEL` 9 (2026-10-02). Tests that exercise an
# override set it themselves. A run that selects live tests keeps
# `LMX_OLLAMA_MODEL`, which only the live provider suite reads, to pick the
# local model it talks to. `LMX_REQUIRE_SANDBOX` is not an `lmx` setting but
# the suite's own: CI's Linux sandbox step sets it so that
# test/lemieux/environment/sandbox_test.exs fails, rather than skips, when no
# sandbox can start, and only that file reads it.
for {name, _value} <- System.get_env(),
    String.starts_with?(name, "LMX_"),
    name not in ["LMX_CONFIG", "LMX_PROJECT_MCP", "LMX_REQUIRE_SANDBOX"],
    not (spend_run? and name == "LMX_OLLAMA_MODEL"),
    do: System.delete_env(name)

# NO_COLOR is a global opt-out people export for every program (no-color.org),
# and the terminal UI honours it from the process environment when a test
# passes no `:env`: it picks the colourless `mono` theme. Exported, it failed
# 22 tests, two of them only after a 180-second wait for a panel whose text
# the mono screen draws without spaces (2026-10-04). Tests that exercise it
# pass `env:` themselves.
System.delete_env("NO_COLOR")

# Omarchy exports OMARCHY_PATH in every desktop session, and `lmx` reads
# Omarchy's Agent Skills from it (`Lemieux.CLI.SystemSkills`). On an Omarchy
# machine every test that discovers a workspace with personal files on would
# otherwise find that machine's skills. Tests that exercise it pass `env:`.
System.delete_env("OMARCHY_PATH")

# Git reads more than the repository it is pointed at, and none of it may
# reach a fixture. From the contributor's global configuration, a
# `commit.gpgsign = true` failed nine tests (and with a real key would have put
# a passphrase or biometric prompt in front of every fixture commit), and a
# `core.hooksPath` ran their pre-commit hook inside fixture repositories and
# failed four more. Git also reads a global ignore file and attributes file
# that no configuration names, `$XDG_CONFIG_HOME/git/ignore` (else
# `~/.config/git/ignore`) and its `attributes` sibling, and the library's own
# Git use honours ignore rules: `Lemieux.Checkpoint.Git` and file search list
# untracked files with `--exclude-standard`. An ignore file holding `*.txt`
# failed five checkpoint tests (2026-10-03).
#
# So Git reads no system-wide configuration or attributes, and a global
# configuration of the suite's own: it names /dev/null for both files, and an
# identity for fixtures that set none. Without one, such a commit would depend
# on whether Git can guess an identity from the machine (`$EMAIL`, the host
# name), which it does on some and refuses on others ("Please tell me who you
# are"). The identity is configuration rather than GIT_AUTHOR_* and
# GIT_COMMITTER_* variables, which would override every fixture's own
# `-c user.name` and so hide whatever identity a test or the library sets. A
# file rather than /dev/null itself, so that a `git config --global` lands
# somewhere harmless instead of failing.
#
# The file is in the checkout's `tmp/`, which only the contributor can write.
# In the system temporary directory, on Linux a /tmp every user shares, a name
# another user could predict is a file they could create first, then fill with
# a `core.fsmonitor` or `core.sshCommand` that runs as whoever runs the suite.
# Named by the OS process, so two runs side by side never share one.
#
# Git also takes configuration from the environment (`git -c` hands it to its
# children in GIT_CONFIG_PARAMETERS), finds a repository through GIT_DIR and
# its relatives, an identity through GIT_AUTHOR_* and GIT_COMMITTER_*, and the
# hooks `git init` installs through GIT_TEMPLATE_DIR. It exports the
# repository variables and the commit's author to the hooks it runs
# (githooks(5)), so a pre-commit hook that ran this suite would otherwise aim
# every fixture's `git init` and `git add` at the contributor's own repository
# and index, and author fixture commits as them.
for {name, _value} <- System.get_env(),
    String.starts_with?(name, ["GIT_CONFIG", "GIT_AUTHOR_", "GIT_COMMITTER_"]) or
      name in ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                 GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_TEMPLATE_DIR),
    do: System.delete_env(name)

git_config = Path.expand("tmp/test-gitconfig-#{System.pid()}")
File.mkdir_p!(Path.dirname(git_config))

File.write!(git_config, """
[core]
    excludesFile = /dev/null
    attributesFile = /dev/null
[user]
    name = Lemieux Test
    email = test@lemieux.invalid
""")

System.at_exit(fn _status -> File.rm(git_config) end)

System.put_env(%{
  "GIT_CONFIG_GLOBAL" => git_config,
  "GIT_CONFIG_NOSYSTEM" => "1",
  "GIT_ATTR_NOSYSTEM" => "1"
})

# Locally served models are not in req_llm's catalog, and it says so at length
# — a multi-line warning per model, several times a run, in the middle of the
# test output. Suppressed here rather than in the library: outside the suite
# that warning is the one thing telling somebody why token counting is missing.
Application.put_env(:req_llm, :warn_unverified_models, false)

# Hosts size the shared stream pool with `Lemieux.ProviderPool.ensure/1`
# before mounting, and resizing it restarts `:req_llm`. The suite exercises
# that call and makes no real connections, so the pool is pre-sized here: a
# call that finds it sufficient restarts nothing mid-suite. The sizing itself
# is tested directly, in isolation.
Application.put_env(:req_llm, :stream_pool_size, 64)

# A proposer seals its evidence and parent trees read-only for the session and
# unseals them in an `after` (`Lemieux.Learning.Proposer`); a materializer
# seals its staging directory the same way. A test killed at its timeout, or a
# run interrupted with Ctrl-C, never reaches the `after`, and ExUnit then
# cannot recreate that test's tmp_dir on any later run ("could not remove files
# and directories recursively ... file already exists"). One timeout under load
# became a permanent failure of meta_test, campaign_test, confirm_test and
# meta_resume_test until someone ran `chmod -R u+w tmp`. The proposer now
# repairs such a tree itself when it tries that ordinal again, but ExUnit fails
# before any test code runs: it empties a test's tmp_dir first. So the trees
# earlier runs left get their write permission back here: the ones ExUnit
# names after a test module, `tmp/<Module>`, and every test module here ends
# in `Test`. Only those. The checkout's `tmp/` also holds whatever else people
# keep there — design notes, the extension workbench's output, discovery
# campaigns that seal their own evidence while they run — and a test run must
# not unseal a campaign running beside it.
case Path.wildcard("tmp/*Test") do
  [] ->
    :ok

  trees ->
    if System.find_executable("chmod") do
      System.cmd("chmod", ["-R", "u+w" | trees], stderr_to_stdout: true)
    end
end

# Multi-node tests need epmd and name the whole VM. Keeping them in the ordinary
# run made CI depend on an operating-system daemon it had not started; the
# `test.distributed` alias starts it explicitly and opts these cases back in.
#
# How long to wait for something that is going to happen. Every failure in
# eight loaded runs (2026-10-01) was a receive, call or test timeout, and each
# failing file passed alone in seconds: the suite was measuring the machine.
# Under identical load a one-second `assert_receive` default failed 54 tests and
# five seconds 26, more than half of those explicit two-second waits — so a test
# that waits for an event should leave the timeout to this default rather than
# name a shorter one. It costs nothing when an assertion passes, and stays far
# below the 60s test timeout. `refute_receive`, which always waits its full
# timeout, keeps ExUnit's 100ms.
#
# One case per scheduler, half of ExUnit's default. Under outside load, how
# many cases run at once decides how long each waits for a CPU, and the suite's
# waits are timers: on 14 cores, 28 cases at load 32 had 59 timing failures,
# and `--max-cases 4` at load 41 had none. Nor is it slower: on the same
# machine at load 17 to 20, 14 cases took 51s and 28 took 75s, with a test
# timing out (2026-10-03). `--max-cases` on the command line still overrides
# it.
#
# On a CI runner, half that again, and no fewer than two. One case per
# scheduler was measured on a workstation whose cores were its own; a hosted
# runner's four schedulers are shares of a busy host, and the 0.8.1 release
# rehearsals (2026-10-06) lost three runs to three different tests, each a
# five-second wait that a stalled scheduler let expire, on code that passed
# the same job minutes before. Fewer cases at once is fewer of the suite's
# own subprocesses and timers competing for those shares. `CI` is the
# variable GitHub Actions sets; a developer's machine keeps one per scheduler.
#
# Logs are kept per test and shown with its failure. A passing run used to
# print some 160 Logger lines between the dots, which taught people that a red
# word in the output means nothing.
max_cases =
  if System.get_env("CI") == "true",
    do: max(div(System.schedulers_online(), 2), 2),
    else: System.schedulers_online()

ExUnit.start(
  exclude: [:live, :eval_live, :distributed],
  assert_receive_timeout: 5_000,
  max_cases: max_cases,
  capture_log: true
)

# The host fixtures are compiled before the TUI test files. Merely aliasing a
# fixture module does not load it, and the status/layout contracts inspect
# callbacks with function_exported?/3 when a test first renders a frame.
Code.require_file("support/tui_fixtures.exs", __DIR__)
