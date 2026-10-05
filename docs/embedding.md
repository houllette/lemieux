# Embedding Lemieux

Lemieux is the Elixir runtime behind `lmx`, and your application can run it
the same way. This page is the reference for a **host**: the application that
runs Lemieux, whether that is `lmx` or yours. It covers what to mount, how to
start and watch a **session** (a supervised process that runs the model/tool
loop), where to attach policy, and how a session's **transcript** (the
append-only record of everything it did) is stored, resumed and forked.

For a complete program that needs no provider key, start with
[First embedded agent](first-embedded-agent.md). To add Lemieux to an
application you already have, read
[Adding Lemieux to an existing app](#adding-lemieux-to-an-existing-app) first.
Then jump to the part your host needs:

- [Mount the runtime](#nothing-starts-on-its-own), [start a session](#starting-a-session),
  and [wait for an answer](#waiting-for-an-answer).
- [Watch events](#watching-one), [attach policy](#where-policy-attaches), and
  [handle stop reasons](#what-the-loop-says-and-when-it-stops).
- [Store and resume sessions](#persistence), [provide tools](#tools), and
  [handle long conversations](#long-conversations).
- [Test your host](#testing-your-host) and
  [diagnose harness composition](#composition-and-diagnostics).

`lmx` is a host like any other. Everything below is what
`Lemieux.CLI.Runtime` does, minus the option parsing. If any of it needed a
privileged path into the library, embedded-only bugs would have nowhere to
show up.

## Nothing starts on its own

Adding `:lemieux` to your dependencies starts no Lemieux processes. There is
deliberately no `mod:` entry in its `mix.exs`, and a test asserts the absence,
so restoring one fails the suite rather than silently changing the contract
every embedder codes against.

Lemieux's dependencies are ordinary OTP applications, though, and they start
with yours. `:req_llm` starts its HTTP pool and a task supervisor, and at boot
it loads `./.env` from the current working directory unless you turn that off.
[Adding Lemieux to an existing app](#adding-lemieux-to-an-existing-app) lists
everything that boots and the settings to make first.

You mount the supervisor into your own tree, and you own its lifecycle:

```elixir
children = [
  MyApp.Repo,
  {Lemieux.Supervisor, name: MyApp.Agents},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The name is how everything else finds it, so one VM can hold several runtimes
(a tenant each, a test each) without a global. `Lemieux.Supervisor` owns
registries and dynamic supervisors for sessions and background commands, plus
the task supervisor for their in-flight work. It also mounts provider
admission: `Lemieux.ProviderLimiter`, unless the host passes
`provider_limiter: {module, opts}` naming its own `Lemieux.Provider.Admission`
implementation, found afterwards through
`Lemieux.Supervisor.provider_admission/1`. The rest is the
`Lemieux.Subagent.Admission` coordinator, a dynamic supervisor for subagent
groups and one for evaluation sandboxes.

`Lemieux.start_session/1`, `Lemieux.resume_session/1` and `Lemieux.run/2`
find the runtime through `supervisor:`, which defaults to
`Lemieux.Supervisor`. Called with nothing mounted under that name, they raise
an `ArgumentError` that says what to do:

```text
no Lemieux runtime is mounted as MyApp.Agents: add {Lemieux.Supervisor, name: MyApp.Agents} to your supervision tree, or call Lemieux.Supervisor.start_link(name: MyApp.Agents) first
```

Sizing ReqLLM's shared stream pool is the host's call, not the mount's: a
library that restarted another application on mount would be deciding
something on the host's behalf. Set `config :req_llm, stream_pool_size: N`
before your application starts
([below](#2-configure-reqllm-before-it-starts)), or call
`Lemieux.ProviderPool.ensure/1` before mounting; `lmx` does the latter in
`Lemieux.CLI.configure/0`. Passing `:provider_pool` or
`:max_concurrent_streams` to the mount raises an `ArgumentError`.

## Adding Lemieux to an existing app

Lemieux runs inside Phoenix, Ash and plain OTP applications, and in
Livebook. This is the checklist for an application that already exists. The
numbers in it were measured, and each says where.

### 1. Add the dependency

```elixir
# mix.exs
{:lemieux, "~> 0.8"}
```

Lemieux needs Elixir 1.19 or later and recent releases of its provider stack:
`req_llm` 1.26 or later, `req` 0.7 or later, `finch` 0.22 or later, `splode`
0.3, and `llm_db` 2026.9.x (2026.9.8 or later in that series, which is what
`req_llm` 1.26.0 accepts). A newly generated Phoenix 1.8 or Ash 3
application resolves them without edits. An older `mix.lock` stops
`mix deps.get` with a message like this:

```text
Because "the lock" specifies "req 0.5.18" and every version of "lemieux"
depends on "req ~> 0.7", "the lock" is incompatible with "lemieux".
** (Mix) Hex dependency resolution failed
```

Update the packages the message names. `mix deps.update lemieux` does not
help, because the conflict is in your lock, not in Lemieux:

```sh
mix deps.update req finch        # locks older than Req 0.7.0 (28 July 2026)
mix deps.update splode           # Ash apps locked before splode 0.3.0 (16 January 2026)
mix deps.update req_llm llm_db   # apps already on a ReqLLM older than 1.26
```

Req 0.7 changes Req itself. Its Finch and Plug adapters replace the
`run_finch`, `put_plug` and `run_plug` steps, the deprecated
`follow_redirects` and `output` steps are gone, and `:params` replaces a
query parameter already on the URL instead of adding a second one. If your
application calls Req directly, read
[Req's changelog](https://hexdocs.pm/req/changelog.html) before you update.

### 2. Configure ReqLLM before it starts

`:req_llm` is an OTP application, so it starts with yours, before any Lemieux
code runs. Put this in `config/config.exs`:

```elixir
# ReqLLM loads ./.env from the working directory into the OS environment at
# boot, for every variable not already set, and runs any $(...) command in
# the file while it reads it. Your release, your tests and every command
# Lemieux's bash tool runs then inherit the result.
config :req_llm, load_dotenv: false

# The most model streams your application has in flight at once: sessions
# plus their delegated children. ReqLLM's default is 8 pools of one
# connection, and a request that lands on a busy pool waits for it.
config :req_llm, stream_pool_size: 16

# Optional: silence the multi-line warning, with a stack trace, that ReqLLM
# prints when it resolves a model outside its catalog, as every Ollama model is.
config :req_llm, warn_unverified_models: false
```

Leave `.env` loading on only if you want ReqLLM to take keys from a `.env`
file. The file is read from whichever directory the VM starts in, in
development, under `mix test` and in a release, and reading it runs the
commands it contains. A host that may start in a directory it does not
control should never load it; the installed `lmx` turns it off for that
reason. In Livebook or a script, pass the same setting to `Mix.install/2`:

```elixir
Mix.install([{:lemieux, "~> 0.8"}], config: [req_llm: [load_dotenv: false]])
```

With the default subagent admission, a runtime can run 8 delegated children
beside their parents, which is 16 concurrent streams: the number
`Lemieux.ProviderPool.ensure/1` sizes for, and the reason for 16 above. With
`stream_pool_size` set at least that high, `ensure/1` has nothing to do. It
resizes a smaller pool by restarting `:req_llm` (with the start type it had),
which drops idle connections and reads `.env` again unless loading is off.

### 3. Mount the runtime

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Lemieux.Supervisor, name: MyApp.Agents},
  MyAppWeb.Endpoint
]
```

The name is yours. Every process Lemieux starts is registered under it
(`MyApp.Agents.SessionSupervisor`, `MyApp.Agents.TaskSupervisor` and so on),
and sessions start with `supervisor: MyApp.Agents`.

### 4. Know what boots with your app

- **Adding the dependency** starts 16 more OTP applications (`:lemieux` is
  one of them, and starts no process) and 17 processes, none of them
  Lemieux's: 11 for `:req_llm` (its supervisor, the
  `ReqLLM.Finch` connection pool, a task supervisor and a token cache), 3 for
  `:websockex` and 3 for `:yamerl`. ReqLLM also creates a few ETS tables and
  one `:persistent_term` entry. No connection is opened.
- **Mounting** `{Lemieux.Supervisor, name: MyApp.Agents}` adds 12 processes,
  all registered under `MyApp.Agents`: registries, the provider limiter,
  subagent admission and empty dynamic supervisors. It writes one
  `:persistent_term` key per mount name.
- **The first session that uses `Lemieux.Providers.ReqLLM`** starts no
  process, but it loads ReqLLM's model catalog (`llm_db`'s 10 MB snapshot)
  into `:persistent_term`, once per VM.

Measured in a Phoenix 1.8.15 production release on Apple Silicon
(Erlang/OTP 29, Elixir 1.20), median of seven boots:

| | Phoenix alone | With Lemieux mounted |
| --- | --- | --- |
| Boot until the host's tree is up | 392 ms | 571 ms |
| Memory at boot (`:erlang.memory(:total)`) | 121 MB | 146 MB |
| Release on disk (compressed) | 42 MB (17 MB) | 78 MB (27 MB) |

The catalog load took about 1.5 s and left about 38 MB in use. While it
ran, memory peaked about 260 MB higher before settling, and the operating
system saw about 300 MB more resident memory, on macOS and in a Linux
container alike. Size instances for that peak. Restricting the catalog with
`config :llm_db, allow: [...]` barely changed either number.

To pay that cost when the application boots rather than in a user's first
session, load the catalog in your application's `start/2`, before the
endpoint starts. An instance too small for the peak then fails at deploy,
not on a request:

```elixir
# In MyApp.Application.start/2, before Supervisor.start_link/2:
{:ok, _catalog} = LLMDB.load()
```

### 5. Decide what tools may see

`Lemieux.Tools.default()` gives the model a `bash` tool that runs as your
application's operating-system user. The bare `Lemieux.Environment.Local`,
the library default, passes the VM's whole environment to every command:
`SECRET_KEY_BASE`, `DATABASE_URL`, provider keys, and anything ReqLLM loaded
from `.env`. Withhold credential-shaped names explicitly:

```elixir
Lemieux.start_session(
  supervisor: MyApp.Agents,
  tools: Lemieux.Tools.default(),
  environment: Lemieux.Environment.Local.new(credentials: {:scrub, []}),
  cwd: workspace_path,
  # ...
)
```

`{:scrub, allow}` withholds every variable whose name contains `KEY`,
`TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`, in any case, except the names in
`allow`. It reads names, never values: `DATABASE_URL` with a password inside
it still passes, and so does a secret under any other name. Command hooks
follow the session's policy; MCP stdio servers take theirs from
`mcp_connect_opts: [credentials: {:scrub, []}]`.
[Credentials](tool-contracts.md#credentials) has the details.

If your application runs inside an OTP release, its VM's environment is not
the one your users or operator started it with: `erlexec` puts the
release's runtime first on `PATH` and sets `BINDIR`, `ROOTDIR`, `EMU` and
`PROGNAME`, and the release script sets `RELEASE_*`. Commands that inherit
that find the release's `erl` before their own, and an Elixir project's
`mix test` then stops with `cannot get bootfile`. Record the environment
your launcher started with, and at boot call
`Lemieux.Environment.Inherited.put/1` once with the differences:

```elixir
Lemieux.Environment.Inherited.put(%{
  "PATH" => original_path,
  "BINDIR" => nil,
  "ROOTDIR" => nil,
  "EMU" => nil,
  "PROGNAME" => nil
})
```

A string sets a variable and `nil` removes it. `Lemieux.Environment.Local`
(and so a sandbox around it), command hooks, MCP stdio servers and the
terminal UI's editor apply these changes before the credential policy; the
Elixir evaluation node does not, because it boots from the VM's own
runtime. `lmx`'s release does this (`Lmx.CLI.inherited/1`). A host started
from its user's own shell needs nothing.

If you record checkpoints for undo, give `Lemieux.Extensions.Checkpoints` a
`:dir` outside every path a sandbox lets commands write. Its git snapshots
run on the host, outside any sandbox, in a repository the agent's commands
can write, so they make private git directories there and run nothing the
repository configures (`Lemieux.Checkpoint.Git`). To report a repository's
state yourself, use `Lemieux.Checkpoint.Git.status/2` (pass `:scratch`, a
directory sandboxed commands cannot write), `locate/1` and `revision/1`,
which follow the same rules, rather than running `git status` in it.

Withholding variables is not isolation: a command still has your application's
files and network. To contain commands, run them somewhere else.
`Lemieux.Environment.Sandbox` runs them under `sandbox-exec` on macOS or
`bwrap` on Linux, with writes limited to the working directory, temporary
directories and tool caches, no network beyond loopback, and common credential
locations hidden from commands and file tools alike
(`Lemieux.Environment.Sandbox.default_hidden/1` lists them). It does not cover
command hooks, MCP servers, the web tools or the Elixir evaluation node, which
run beside the environment rather than through it. A container or a remote
workspace is a `Lemieux.Environment` of your own, or a configured
`Lemieux.Tools.Bash.new(runner: ...)`
([Where policy attaches](#where-policy-attaches)). A multi-tenant web
application should not run the model's commands inside its own release.

### 6. Trim the release (optional)

ExCmd, which runs commands for Lemieux, ships its helper executable for six
platforms plus a generic copy, about 12 MB. A release runs on one platform,
so you can drop the rest, as `lmx`'s own release build does:

```elixir
# mix.exs
def project do
  [
    # ...
    releases: [my_app: [steps: [:assemble, &prune_ex_cmd_helpers/1]]]
  ]
end

# Keeps only the helper ExCmd uses on the build machine, so build on the
# platform you deploy to. executable_name/0 is ExCmd's own undocumented
# helper: re-check this step when you upgrade ExCmd.
defp prune_ex_cmd_helpers(release) do
  keep = Mix.Tasks.Compile.Odu.executable_name()

  for path <- Path.wildcard(Path.join(release.path, "lib/ex_cmd-*/priv/odu*")),
      Path.basename(path) != keep,
      do: File.rm!(path)

  release
end
```

In the measured release this saved 10.9 MB, and a scripted `bash` tool call
still ran.

### 7. Run commands in a container

Each command runs in a process group of its own, so a timeout or a
cancellation stops everything it started. Starting the group needs `setsid`
or `perl`; signalling it needs a `kill` executable or a POSIX `sh`, whose
builtin `kill` Lemieux uses on images that ship no `procps`, such as the
Debian slim image Phoenix's generated release Dockerfile runs on.
`Lemieux.Environment.Local.ExCmd.process_groups?/0` says whether a machine
has what it needs. If the VM stops while a command is running (a deploy's
SIGTERM, a crash, `kill -9`), a small watchdog process kills that command's
group. A SIGKILL sent to the VM's whole process group takes the watchdog
with it.

## Starting a session

```elixir
{:ok, session} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: MyApp.AgentStore.new(MyApp.Repo),
    model: "anthropic:claude-sonnet-5",
    cwd: worktree_path,
    subscriber: self(),
    tools: Lemieux.Tools.default(),
    tool_profile: %{"id" => "tenant-standard", "allow" => "all"},
    max_cost_usd: 4.00,
    hooks: [before_tool_call: &MyApp.Policy.approve/2]
  )

:ok = Lemieux.Session.prompt(session, "make the failing test pass")
```

`MyApp.AgentStore` is a database-backed store; [Persistence](#persistence)
has one in full. Omitting `:system` uses the short `Lemieux.Prompt.default/0`;
passing a string replaces it, and passing `system: nil` explicitly disables
it. The library does not discover `AGENTS.md` or Agent Skills on its own:
that composition is a choice made by the `lmx` host.
[System prompts](configuration.md#system-prompts) covers the library, CLI,
compaction, resume, and delegated-child prompt paths.

### When a session does not start

Mistakes in the options raise an `ArgumentError` in the caller, before
anything starts. `start_session/1` checks them in this order:

- **`:provider`** missing, or not a `{module, state}` pair. The message says
  to build one with `Lemieux.Providers.ReqLLM.new()`, or with
  `Lemieux.Providers.Scripted.new(script)` in a test. A bare module gets its
  own message. The value itself is never printed, because providers and
  stores carry credentials.
- **`:store`** missing, or not a `{module, state}` pair:
  `a session needs :store: build one with Lemieux.Store.JSONL.new("sessions")`.
- **`:model`** missing from a new session:
  `a new session needs :model, a req_llm model specification such as "anthropic:claude-sonnet-5"`.
  A resumed session may leave the model to its transcript.
- **The mount**: nothing mounted under `:supervisor`, as
  [above](#nothing-starts-on-its-own).

`Lemieux.Agent.Session` and subagent groups report these mistakes as results
instead. Its `run/2` returns
`{:error, {:provider, :invalid}}` (or `:store`) for a value that is not a
`{module, state}` pair, and `{:error, {key, :required}}` for a provider or
model left out, or a provider, store or model given as `nil`. In a subagent
group, a provider from the host's `:providers` map or `:provider_factory`
that is not a pair fails only that child, with
`{:start_failed, {:invalid_session_options, :provider}}`, while its siblings
run; a factory that raises still takes the whole group down. None of these
include the value.

Other refusals are returned. A transcript another live session holds gives
`{:error, {:session_locked, holder}}` ([Persistence](#persistence)).
`Lemieux.resume_session/1` (and `run/2` given `:resume`) checks `:store`
and reads the transcript before the rest of the checks above, so it returns
`{:error, :not_found}` for an id nothing was written under, even when no
runtime is mounted, and `{:error, {:ambiguous, ids}}` for a shorthand two
stored sessions share.

### Starting from a harness

A **harness** is everything a session runs with: instructions, tools, hooks,
limits and strategies. Its options are fields on `Lemieux.Harness`, and
`start_session/1` takes the struct as `:harness`. Provider, store, model,
supervisor, subscriber, and working directory remain separate host options.
The point of the struct is that it can be handed to code: a
`Lemieux.Extension` receives the harness as it stands and returns it as it
should be, and `Lemieux.Harness.assemble/2` applies a list of them in order.

```elixir
{:ok, harness} =
  Lemieux.Harness.assemble(
    Lemieux.Harness.new(tools: MyApp.agent_tools(tenant), max_cost_usd: 4.00),
    [
      {MyApp.Audited, log: audit_log},
      {Lemieux.Extensions.Delegation, model: model, provider: provider, cwd: worktree_path}
    ]
  )

{:ok, session} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: provider,
    store: store,
    model: model,
    cwd: worktree_path,
    harness: harness,
    hooks: [before_tool_call: &MyApp.Policy.approve/2]
  )
```

An option named in the keyword wins over the same field on the harness: the
harness is behaviour that arrived through code, the keyword is the host
speaking now. Provider, store, model, supervisor, subscriber and working
directory are never harness fields. They are yours, and no extension can
reach them. Which extensions shaped a session is written into every
request's harness snapshot. [Extensions](extensions.md) has the contract, a
worked example and the list `lmx` ships.

### Defining the agent experience

Conversation tools are recorded and restored because they are part of what a
session was configured to use. A host may also pass `:host_tools`: current
runtime capabilities that are validated and policy-governed like ordinary
tools but deliberately neither recorded nor restored. Re-supply them on
resume. This is appropriate for tenant-scoped loaders, credentials, and other
capabilities whose authority belongs to the current host.

An application can opt into the standalone TUI's filesystem profile by
applying the same extension the TUI applies:

```elixir
{:ok, harness} =
  Lemieux.Harness.assemble(
    Lemieux.Harness.new(system: MyApp.agent_prompt(), tools: MyApp.agent_tools(tenant)),
    [
      {Lemieux.Extensions.Workspace,
       cwd: worktree_path, personal?: false, plugin_dirs: installed_plugin_dirs}
    ]
  )

{:ok, session} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: provider,
    store: store,
    model: model,
    cwd: worktree_path,
    harness: harness
  )
```

The extension composes persona, instructions, memory and the skill catalog
over the prompt, appends the allowlisted `skill` loader to `:host_tools`,
applies the learned overlay (a repository's `.lmx/harness.json` may only add
prompt text; tool descriptions come only from a personal
`~/.lmx/harness.json`, which `personal?: false` leaves out), and fills
`harness.skills` and `harness.notices` for a host with a screen.
`Lemieux.Extensions.Workspace.Discovery` is the reading half, for a host that
wants the files and not the composition. Or an application can ignore both
and assemble persona, instructions, memory, skills, and loaders from a
database or API. The library imposes neither choice.
[Agent-harness experience](configuration.md#workspace-discovery) records the
standalone TUI profile and the reasons executable plugin components remain an
explicit host decision.

### Routing model calls through a gateway

Configure the `req_llm` provider when an embedded host sends model traffic
through an API gateway or model proxy:

```elixir
provider =
  Lemieux.Providers.ReqLLM.new(
    base_url: System.fetch_env!("MY_APP_LLM_BASE_URL"),
    api_keys: %{anthropic: tenant.anthropic_key, openai: tenant.openai_key},
    # Opt in only when this URL is a trusted gateway that should join the
    # caller's active OpenTelemetry trace.
    propagate_trace_context: true
  )

{:ok, session} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: provider,
    store: MyApp.AgentStore.new(MyApp.Repo),
    model: "anthropic:claude-sonnet-5"
  )
```

`base_url` replaces the selected provider's API base; `req_llm` still chooses
the provider wire protocol and appends its request path. The gateway therefore
has to expose provider-compatible endpoints. This does not configure a generic
HTTP CONNECT forward proxy.

The URL is runtime provider state, not conversation configuration. It is never
written into the transcript, so a resumed session uses the route supplied by
the host that resumes it and does not retain an old deployment URL or embedded
credentials.

For an interactive provider picker, construct the provider with the same
tenant/project key map used for requests and call
`Lemieux.Provider.available_models/2`. A placeholder scalar key is not valid
discovery because it has no provider identity.
`Lemieux.ModelCatalog.provider_options/0` is the public opt-in compatibility
profile used by `lmx`; it keeps verified fallback models coupled to the
transport route they require.

`propagate_trace_context: true` adds the active W3C context without replacing
an explicit host `traceparent` or `tracestate`. It configures no tracer or
exporter. [Telemetry](telemetry.md#opentelemetry-bridge) shows how to attach
the OpenTelemetry bridge in a standalone host, with an Ixway gateway, and in
a host that already records its own agent spans.

### Models served by Ollama

`Lemieux.Providers.ReqLLM` treats `ollama:` models, the ones a local Ollama
daemon serves, differently in three ways. None of them applies when the host
routes Ollama traffic elsewhere (`:route`, or a `:transport_routes` entry).

- **An answer has a ceiling.** A local model publishes no output limit, so a
  request carries `max_tokens: 16_384` unless the request, the host's options
  or the catalog sets one. `:local_max_tokens` changes it; `nil` sends none.
- **The first token may be minutes away.** Ollama sends nothing while it
  reads a long prompt, so the transport and stream-idle timeouts are raised to
  at least 15 minutes, never lowered. `:local_idle_timeout` changes the floor;
  `nil` leaves the timeouts as configured. Hosted models keep the adapter's
  two-minute `:receive_timeout`; raise it for slow reasoning models.
- **The window is the daemon's.** Ollama sizes a model's context window when
  it loads the model and silently drops what does not fit, so the adapter
  asks the daemon (`Lemieux.Providers.OllamaWindow`: `/api/ps` for a loaded
  model, else `/api/show`) instead of the catalog. After every answer the
  provider reports the window it served with as a `{:context_window, tokens}`
  provider event, and the session plans compaction against it.
  `ollama_window: false` turns the lookups off.

```elixir
provider =
  Lemieux.Providers.ReqLLM.new(
    local_max_tokens: 8_192,
    local_idle_timeout: :timer.minutes(20)
  )
```

The window is set where the daemon runs, for example with
`OLLAMA_CONTEXT_LENGTH`; [Use a local model](providers.md#use-a-local-model)
has the setup `lmx` users follow. A session whose window is too small for its own
instructions says so ([Long conversations](#long-conversations)).

### The session process

A session is a process that owns a transcript and is the only writer of its
store. It is `restart: :temporary` on purpose: a supervisor that restarted one
would replay the options it was started with rather than the conversation it
was having, producing a process with the same id and an empty transcript,
which is the shape most likely to be mistaken for a working session. The
transcript is durable; resuming is a decision, not a reflex.

### One prompt is not one request

`prompt/2` returns as soon as the work starts. The session then answers, calls
tools, reads their results and answers again, staying busy across all of it and
emitting `{:finished, _}` once. That is the unit a person waits for. It is
bounded by `:max_turns`, because a model that calls a failing command in a loop
is not hypothetical and the bill arrives regardless.

`:max_cost_usd` is a session-lifetime spend gate. Immediately before every
provider request, including a compaction request, Lemieux adds measured spend
to a pessimistic, cache-aware estimate that prices the current input as
uncached plus the request's maximum output. When the total would exceed the
cap, no request is started and the ending is
`{:finished, {:budget, %{spent: spent, estimate: estimate, cap: cap}}}`. Unknown
pricing also stops: an unpriced request is not silently treated as free. Set a
realistic `:max_tokens` in `:params` when the model's catalog maximum is much
larger than the output this session needs.

### Delegating bounded investigations

An embedded host can give a parent one `delegate` tool backed by explicit
`Lemieux.Subagent.Definition` values. The host builds it and passes it in
`:tools` like any other tool:

```elixir
delegate =
  Lemieux.Subagent.Delegate.new([scout],
    snapshot: %{"kind" => "git", "revision" => current_commit},
    max_cost_usd: 2.25
  )

Lemieux.start_session(supervisor: MyApp.Agents, tools: Lemieux.Tools.default() ++ [delegate], ...)
```

Each invocation runs one to three fresh, temporary child sessions with
certified read-only tools, separate transcripts, and individual turn/time/cost
limits. The parent remains the only writer and receives one bounded,
input-ordered, all-settled structured result.

The host owns the definitions, immutable snapshot, rate-domain identity, and a
mandatory tree cost budget; none are model-selectable. The tool is never
restored from a transcript: it is a struct holding functions and authority,
so pass it again when resuming. What only the session knows, the tool reads
from its context when it runs, which is why the same struct is good in any
session it is handed to. Direct `spawn`, `spawn_many`, `inspect`, `steer`,
`cancel`, and `await` APIs are also available when host code owns
orchestration. See [Delegated investigations](subagents.md) for the complete
configuration, lifecycle, event, replay, and authority contracts.

## Watching one

Events go to every subscriber pid as `{:lemieux, session_id, event}`. A
subscriber is nothing more than an address: it is not linked, not monitored and
not required. `subscriber:` accepts one pid or a list when the session starts;
watchers may also attach and detach while it runs:

```elixir
:ok = Lemieux.Session.subscribe(session, observer_pid)
:ok = Lemieux.Session.unsubscribe(session, observer_pid)
```

A Phoenix LiveView that streams an answer as it arrives keeps a draft per
assistant entry, then replaces it with the stored entry. Assign
`drafts: %{}` and `done: false`, and `stream(:output, [])`, in `mount/3`,
then:

```elixir
def handle_info({:lemieux, _session_id, {:text_delta, %{id: id, text: text}}}, socket) do
  drafts = Map.update(socket.assigns.drafts, id, text, &(&1 <> text))

  {:noreply,
   socket
   |> assign(drafts: drafts)
   |> stream_insert(:output, %{id: id, text: drafts[id]})}
end

def handle_info({:lemieux, _session_id, {:entry, %{type: :assistant, id: id, payload: payload}}}, socket) do
  text = for %{"type" => "text", "text" => t} <- payload["content"], into: "", do: t

  {:noreply,
   socket
   |> assign(drafts: Map.delete(socket.assigns.drafts, id))
   |> stream_insert(:output, %{id: id, text: text})}
end

def handle_info({:lemieux, _session_id, {:finished, _reason}}, socket),
  do: {:noreply, assign(socket, done: true)}

# A session sends many more events than these (see Lemieux.Session).
def handle_info({:lemieux, _session_id, _event}, socket), do: {:noreply, socket}
```

Each `stream_insert/3` with an id already in the stream replaces that item,
which is why the draft accumulates: inserting each fragment on its own would
show only the last one. Keep the last clause. Without it, the first event the
LiveView does not match crashes it.

**Session lifetime is decoupled from whoever is watching.** A LiveView that
disconnects, a CLI that exits, a host that crashes and restarts: none of them
stop the agent or lose its work. A subscription receives only future events;
reattaching is reading the store for what was missed and then subscribing the
replacement pid. There is no live-stream replay protocol, because the
transcript is the replay.

Plain messages rather than a pub-sub dependency: several host processes may
subscribe directly, or a host that wants `Phoenix.PubSub` may subscribe one
process and broadcast from it.

The delta `id` is the id of the assistant entry that will eventually arrive in
`{:entry, entry}`. A host can broadcast deltas without persisting them, buffer
by that id, then replace the transient buffer with the durable entry without
guessing which message a chunk belonged to.

The events are listed on `Lemieux.Session`. The ones most hosts render are
`{:entry, entry}`, the two delta events, `{:tool_call, call}`,
`{:tool_approval, call}`, `{:question, question}` and `{:finished, reason}`.

`{:usage, usage}` and the assistant entry's `usage` field share the stable
string-keyed contract documented by `Lemieux.Usage`: `input_tokens`,
`output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_usd`, and
`model` are always present. `cost_usd` is `nil` when the model cannot be priced,
never `0.0` merely because pricing is unknown. Provider-specific keys are
preserved as additional fields.

`Session.snapshot/1` additionally reports `usage.direct`, `usage.delegated`
and `usage.total`, plus `inclusive_spent_usd`. The existing `spent_usd` remains
the direct parent-session amount, including declared native-tool charges, used
by its cost gate; delegated trees have their own mandatory admission budget.
This split lets a host show the whole bill without silently changing either
budget's enforcement semantics.

Nested live child events carry their own `{:usage, usage}`. A root frontend
should add those to its visible run total but must not apply them to the
parent's context-window position: child sessions have fresh contexts that are
never replayed in the parent's next request.

A status line should ask `Lemieux.Session.info/1` rather than `snapshot/1`.
It answers the same questions without copying the transcript out of the
session, and a few a snapshot cannot: `requests` against `max_requests`,
whether startup MCP connections have settled (`ready?`, with each server's
state under `mcp`), and whether the model's context window is known
(`context_window_known?`).

### Waiting for an answer

A job that wants an answer rather than a stream calls
`Lemieux.Session.await/3`. It subscribes a private collector before
prompting, so nothing is missed and none of the session's events land in the
caller's mailbox, and returns when the prompt's work is finished:

```elixir
{:ok, %{text: text, stop_reason: :stop, usage: usage, entries: entries}} =
  Lemieux.Session.await(session, "Summarise README.md", on_event: &IO.inspect/1)
```

`text` is the last answer's text, `usage` is the prompt's own and `entries`
are the ones it wrote. `:timeout` defaults to `:infinity` (a session is
bounded by its own budgets), and a timed-out wait leaves the session working.
The session is monitored for the whole wait: one that goes down before the
prompt finishes, or was already gone, answers
`{:error, {:session_down, reason}}` with its exit reason instead of a wait
that never ends.

`Lemieux.run/2` is the shortest embedding: it starts a session (or resumes
one, given `:resume`), awaits one prompt, and stops the session again.

```elixir
{:ok, result} =
  Lemieux.run("Summarise README.md",
    supervisor: MyApp.Agents,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: Lemieux.Store.JSONL.new("sessions"),
    model: "anthropic:claude-sonnet-5",
    max_requests: 20
  )
```

## Where policy attaches

Tools run with the full permissions of whoever launched the host. The session
core has no permission layer, and that is a decision rather than an omission:
hosts differ completely in what they can enforce, and a half-policy in the
core would be one more thing to work around. What the core provides is the
seam, a `before_tool_call` hook. `Lemieux.Extensions.Permissions` is the
shipped policy built on it, the one `lmx --permission-mode` applies: the
modes `:ask`, `:accept_edits`, `:auto`, `:full_auto` and `:read_only`, and
allow, deny and ask rules such as `"Bash(npm run test:*)"`. Apply it with
`Lemieux.Harness.assemble/2`, or write your own:

```elixir
hooks: [
  before_tool_call: fn call, context ->
    cond do
      call.name == "bash" and dangerous?(call.arguments) -> {:deny, "not that one"}
      call.name in ~w(write edit) -> :pending
      true -> :allow
    end
  end,
  after_tool_call: fn _call, _result, _context -> :telemetry.execute(...) end
]
```

`before_tool_call` also answers `{:rewrite, args}` to run the call with
different arguments, and `after_tool_call` receives `(call, result, context)`
for observing; its return value is ignored.

`:pending` is the interesting one: the call parks, the session emits
`{:tool_approval, call}`, and nothing runs until `Lemieux.Session.resolve_tool/3`
answers or the timeout denies it. That is the same mechanism `ask_user` and MCP
elicitation use, so a host that can answer one can answer all three.

The timeout is `:approval_timeout`, five minutes unless the host says
otherwise; a host with a person always at the screen passes `:infinity`.
The call's own tool deadline is paused while it is parked, so a person who
takes longer than the tool's deadline to decide does not come back to a call
that already timed out. A call that ends while parked takes its waiting
approval with it, and a late answer is refused with `{:error, :unknown_call}`
rather than recorded as approving a call that never ran.

Hooks see **every** tool call, including MCP tools. A tool a host cannot write
a policy for would be a hole in the policy.

`context.tool_descriptor` is the complete descriptor-v1 snapshot for the
effective tool. It gives policy stable identity, provenance, declared effects,
approval hints and resource scopes without inferring intent from a shell or
code string. See [Governed tool contracts](tool-contracts.md) for descriptors,
structured results, host profiles, execution limits and request-level catalog
evidence.

Policy and execution are separate seams. When bash must run somewhere other
than the host BEAM, for example inside a session container, pass a configured
tool instead of reimplementing it:

```elixir
tools = [
  Lemieux.Tools.Read,
  Lemieux.Tools.Write,
  Lemieux.Tools.Edit,
  Lemieux.Tools.Bash.new(runner: &MyApp.Sandbox.exec/2)
]
```

The runner receives `(command, cwd: ..., timeout_ms: ...)` and returns
`{:ok, combined_output, exit_status}` or `{:error, reason}`. Lemieux still owns
timeouts, output sanitation and truncation, and the rule that a non-zero exit
is a tool result rather than a tool failure. Because a configured tool contains
a function, pass it again when resuming; executable host state is not restored
from a transcript.

Without a configured host runner, `Lemieux.Environment.Local` uses ExCmd's
demand-driven process API. A monitored command owner performs one read per
consumer demand while Lemieux retains its semantic timeout, output-limit, and
exit-status stream. The environment boundary remains the extension point: a
container or remote workspace does not need ExCmd and should implement the
same `Lemieux.Environment.run/3` event contract directly. On Windows, commands
run under Git for Windows' bash (`Lemieux.Environment.Local.find_bash/0`
says which), never WSL's.

The same bash tool starts session-owned background commands with
`%{"command" => command, "background" => true}`. Later calls poll with
`%{"task_id" => id}` or await with `%{"task_id" => id, "wait_ms" => 30_000}`;
wait expiry returns current state without cancelling the command. Embedded
hosts can call `Lemieux.Background.start/1`, `poll/3`, `await/4`, and `cancel/3`
directly. See [Background commands](tool-contracts.md#background-commands) for ownership,
retention, output bounds, and host-runner behavior.

The same list also supports `session_start`, `attention`, `user_prompt`,
`prepare_next_turn`, `stop`, `error` and `session_end` lifecycle callbacks.
`attention` is an observation hook: it receives
`%{state: :waiting, call_id: id, kind: kind}` when a call parks and
`%{state: :working}` when the final parked call releases. `prepare_next_turn`
receives `(request, context)` immediately before the budget check and
dispatch and returns `{:ok, %Lemieux.Request{}}` or `{:deny, reason}`. It is
the seam for adding fresh context or choosing tools for one turn.
External command hooks use the same seam; `Lemieux.Hooks.Config.read/1` turns a
versioned JSON file into session hooks, while `lmx --hooks FILE` is the CLI
form. Command hooks receive JSON on stdin and use exit `2` or a structured deny
to block.

`stop` is a decision hook, not an observation hook. It must return `:allow` or
`{:deny, feedback}`; its callback is not wrapped by the observer rescue path.
Do not use `stop` merely to send a notification; use `attention`, `error`, or
`session_end` for best-effort observation. An invalid `stop` return crashes its
hook task, is logged as a failed stop hook, and the session completes the stop.

`session_end` fires from the session's `terminate/2`. A host that halts the VM
without stopping the session never sees it, so stop the session first.
`Lemieux.CLI.Runtime.stop_session/1` is the CLI's form of that stop.

See `Lemieux.Hooks` and [Hooks](hooks.md).

Lemieux emits redacted harness events for prompts, turns, provider admission,
first output, tools, compaction and cancellation. Attach to
`Lemieux.Telemetry.events/0`; use lifecycle hooks for policy and attach to
ReqLLM's native events for provider/HTTP and token detail. See
[Telemetry](telemetry.md) for names, measurements and the metadata
allowlist.

## What the loop says, and when it stops

Two more of the loop's opinions sit behind options rather than literals, and
take the same shape as everything else here: a module, with the shipped
default being the module that declares the behaviour, so the two cannot
drift.

`:messages` is the wording the session puts in front of the model on its own
account: the denial a call becomes when nobody approves it in time, the
catalog notice when the tools change, the text that stands in for a result a
tool never reported, why the work stopped. `Lemieux.Messages` is both the
default and the contract. A host that wants a denial to name the policy
behind it, or the model told in another language, implements the behaviour
and inherits the shipped sentences it does not override:

```elixir
defmodule MyApp.Messages do
  @behaviour Lemieux.Messages

  @impl true
  def approval_timed_out(ms), do: "no reviewer answered within #{ms}ms; ask in #agents"
end

Lemieux.start_session(supervisor: MyApp.Agents, messages: MyApp.Messages, ...)
```

`:guard` is what decides, after each round of tool calls, whether the loop
goes on. The shipped `Lemieux.Session.Guard` stops a round that has come back
identical three times, a window whose calls mostly repeat earlier ones with
the same answer, and a prompt that has spent `:max_turns`; the session keeps
that record whichever guard reads it. A host running a legitimately
repetitive job, or one with its own notion of progress, passes a module or
`{module, state}`:

```elixir
defmodule MyApp.Guard do
  @behaviour Lemieux.Session.Guard

  @impl true
  def decide(budget, %{turns_taken: taken}) when taken >= budget,
    do: {:stop, :enough, "#{budget} rounds is what this job gets"}

  def decide(_budget, _view), do: :continue
end

Lemieux.start_session(supervisor: MyApp.Agents, guard: {MyApp.Guard, 12}, ...)
```

The reason is what `{:finished, reason}` carries and the run evidence
records; the message is written to the `:error` entry that ends the prompt.
Neither option is recorded in the transcript or restored from one. Like
hooks, they are the host's behaviour, and a resumed session gets the ones the
host resuming it passes.

The shipped guard leaves out results that say what they report on is still
in progress: `structured_content` with a `"status"` of `running`, `pending`,
`queued` or `in_progress`, as a polled background command reports, or
`metadata` with `"in_progress" => true`. Waiting on a job asks the same thing
and hears the same answer until it finishes; that is not a loop.

### When a request fails

A request that fails in a way the provider may not repeat (a 5xx, an
overload, a rate limit, a stream that went quiet or broke off) is sent
again, up to six attempts with a doubling backoff (2, 4, 8, 16, 32 seconds,
or the provider's `retry-after`). That holds after the model had started
answering too: tool calls run only once a response is complete, so nothing a
partial answer contained has taken effect. What it had said is kept as an
assistant entry marked `"partial" => true`, never sent again, and
`{:provider_retry, %{after_output: true}}` says so. Quota, billing and
authentication failures are never retried. `:provider_retry` changes the
numbers, `after_output: false` retries only failures that came before any
output, and `false` turns retries off for a host that schedules its own.

## Steering a running session

`Lemieux.Session.steer/2` is guaranteed to join the conversation before the
next provider request is built. It cannot alter the request already in flight.
If the current response calls tools, the steer is appended after those tool
results and before the follow-up model request; if the response would otherwise
finish, the queued steer causes one more request (subject to the turn and cost
bounds). An idle steer waits for the next explicit prompt and starts no work on
its own. `Lemieux.Session.revoke_steer/2` takes a steer back while it is still
waiting, and answers `{:error, :already_sent}` once it has gone.

## Hosting the terminal UI elsewhere

`Lemieux.TUI.start_link/1` forwards ex_ratatui transports. A host that owns an
in-memory ANSI session can render the same UI without a local tty:

```elixir
terminal = ExRatatui.Session.new(120, 40)
writer = fn bytes -> MyApp.Terminal.write(bytes) end

Lemieux.TUI.start_link(
  start: start_session,
  size: {120, 40},
  name: nil,
  transport: {:session, terminal, writer},
  background: :dark,
  command_policy: fn
    {:attach, _target} -> {:deny, "attaching is disabled by this host"}
    :mcp_status -> {:deny, "MCP is disabled by this host"}
    {:mcp_add, _path} -> {:deny, "MCP is disabled by this host"}
    {:mcp_remove, _name} -> {:deny, "MCP is disabled by this host"}
    {:mcp_reconnect, _name} -> {:deny, "MCP is disabled by this host"}
    _action -> :allow
  end
)
```

On a local terminal the screen asks the terminal whether its background is
light, unless a theme was chosen (`theme:`) or `NO_COLOR` is set, and reads
`COLORTERM` for how many colours it draws. Over a host's own transport it
cannot ask, so it uses what the host states: `background:` (`:light`,
`:dark` or `:unknown`, the default there) picks the palette, and `colours:`
(`:truecolor`, the default there, or `:ansi256`) the colour depth. On a local
terminal the same options override the detection. `trap_signals: true` traps
SIGTERM while a local screen runs, so a `kill` leaves the terminal restored
rather than inside the alternate screen. It is off by default because how the
VM stops is the host's decision, it is ignored with `test_mode` and remote
transports, and SIGHUP is never trapped.

`status_line:` takes a module implementing `Lemieux.TUI.Status` and hands that
host the one permanently visible row. The four things the shipped layout puts
there are the four that earned it, not the only four anybody wants, and a host
billing a team or routing through a gateway has its own. It returns any widgets
`ExRatatui` can draw and may ask for more than one row; the rects are clamped
to the row and the height to a third of the frame, so a replacement cannot
paint over the transcript. `followups:` takes a module for the follow-up
hint's guess, beside it. `processing:` takes the words a running turn is
labelled with. See [Terminal UI](terminal-ui.md#replacing-the-status-line).
Through `lmx`, all three are fields on the `Lemieux.Harness` the screen is
drawn from: `Lemieux.CLI.TUI` forwards the harness whole and
`Lemieux.TUI.start_link/1` reads them from `harness:`, so an extension can
set them the way it sets anything else. A host that starts the screen itself
passes `harness:` the same way, or the individual options, which win.

Two more options matter to a host that keeps the screen up for long.
`task_supervisor:` names the `Task.Supervisor` the screen runs its
off-loop work under (`/compact`, `/undo`, `/diff`, `/export`, `!command` and
the like); `lmx` passes its runtime's, `Lemieux.Supervisor.task_supervisor/1`.
Without one, that work is linked to the screen, so a call that crashes on a
live session, a timeout say, takes the screen down with it. A host that
finds models itself, as `lmx` asks a local Ollama, sends the screen
`{:models_discovered, models}`, or passes the same list as
`discovered_models:` at start. An entry is a model spec, or
`{:preferred, spec}` for the one the host would choose for that spec's
provider: it goes first, the rest of a message follow in alphabetical
order, and what an earlier message found keeps its place. When the session
has no model of its own for a provider, `/provider NAME` switches to the
host's preferred model for it (`preferred_models:`, such as a configured or
recently used one) if that was discovered, else to the first of `NAME`'s
discovered models.

The host must depend on the optional `ex_ratatui` itself:

```elixir
{:ex_ratatui, "~> 0.16"}
```

Lemieux compiles its terminal UI only when `ex_ratatui` is present at compile
time. With Lemieux as a `path:` dependency, Mix does not recompile it when you
add or remove `ex_ratatui`, so run `mix deps.compile lemieux --force`
afterwards. With it in place, `mix lmx.tui` opens the same terminal UI `lmx`
does from inside your application's project, after starting your
application.

The host owns input and resize forwarding as well as the writer; Lemieux
remains only the app rendered over that transport. The policy receives parsed
actions, not strings. It is checked both while building help/completion and
again at dispatch, so hiding a command is never the authorization boundary.
`/attach` is its own action and is not implied by authorizing the `elixir`
tool. `/elixir` and `/tools enable` still flow through the session's immutable
`tool_profile`; live UI choices can only narrow or select inside the host cap.

## Persistence

A store is a `{module, state}` pair implementing three callbacks. `lmx` uses
`Lemieux.Store.JSONL`, which writes a file per session that you can `grep`. A
host with a database implements the behaviour over its own tables and gets
transcripts inside its own transactions and its own retention policy.

The contract is small: appends are ordered and durable, `read/2` returns
exactly what `append/3` was given, in order, and `list_sessions/1` lists ids
oldest first. `read/2` must not raise: a transcript it cannot understand is an
`{:error, reason}`, never an exception and never a conversation with a part
missing. A store is not asked to be a queue or to notify anybody. A session has
exactly one writer, its own process, and that is where the ordering guarantee
comes from.

### A database-backed store

This one keeps transcripts in the application's own Ecto repository, one row
per entry. It was checked in a Phoenix application: a session wrote through
it, was stopped, and resumed from it with its earlier turn in the next
request.

```elixir
defmodule MyApp.Repo.Migrations.CreateLemieuxEntries do
  use Ecto.Migration

  def change do
    create table(:lemieux_entries) do
      add :session_id, :string, null: false
      add :position, :integer, null: false
      # One Lemieux.Entry.encode!/1 line, stored verbatim.
      add :line, :text, null: false
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:lemieux_entries, [:session_id, :position])
  end
end
```

```elixir
defmodule MyApp.AgentStore do
  @moduledoc "A Lemieux.Store over the application's own Repo."
  @behaviour Lemieux.Store

  import Ecto.Query

  # :caller is for tests under Ecto's SQL sandbox; :log is Ecto's own option.
  def new(repo, opts \\ []), do: {__MODULE__, {repo, Keyword.take(opts, [:caller, :log])}}

  @impl true
  def append({repo, opts}, session_id, entries) do
    repo.transaction(
      fn ->
        last =
          repo.one(
            from(e in "lemieux_entries",
              where: e.session_id == ^session_id,
              select: max(e.position)
            ),
            opts
          ) || 0

        now = DateTime.utc_now()

        rows =
          entries
          |> Enum.with_index(last + 1)
          |> Enum.map(fn {entry, position} ->
            %{
              session_id: session_id,
              position: position,
              line: Lemieux.Entry.encode!(entry),
              inserted_at: now
            }
          end)

        repo.insert_all("lemieux_entries", rows, opts)
      end,
      opts
    )
    |> case do
      {:ok, _inserted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read({repo, opts}, session_id) do
    query =
      from e in "lemieux_entries",
        where: e.session_id == ^session_id,
        order_by: e.position,
        select: e.line

    case repo.all(query, opts) do
      [] -> {:error, :not_found}
      lines -> {:ok, Enum.map(lines, &Lemieux.Entry.decode!/1)}
    end
  rescue
    # Lemieux.Store forbids raising out of read/2.
    error -> {:error, {:unreadable, session_id, Exception.message(error)}}
  end

  @impl true
  def list_sessions({repo, opts}) do
    query =
      from e in "lemieux_entries",
        group_by: e.session_id,
        order_by: min(e.id),
        select: e.session_id

    {:ok, repo.all(query, opts)}
  end
end
```

Store each line verbatim: it may hold `Lemieux.Transcript.Dedup` references
(below), which a resumed session expands. Ecto logs every query in
development, transcript lines with their prompts included, so
`MyApp.AgentStore.new(MyApp.Repo, log: false)` keeps them out of your logs.
In an `async: true` test under `Ecto.Adapters.SQL.Sandbox`, the process that
writes is the session, not the test, so pass the test's pid:
`MyApp.AgentStore.new(MyApp.Repo, caller: self())`. For the optional lock
below, a Postgres advisory lock is the natural fit.

### One writer per transcript

One writer per *transcript* is a different promise: two hosts resuming the same
id are two sessions with one file. A store that can tell implements the
optional `lock/2` and `unlock/3` callbacks; the session claims its transcript
before it writes and releases it when it stops, and a second session on a
claimed id fails to start with `{:error, {:session_locked, holder}}`, where
`holder` is `%{host:, os_pid:, process:, since:, path:}`: enough to tell a
person which process holds it and which lock file to delete if it is gone.
`transcript_lock: false` opts a session out.

`Lemieux.Store.JSONL` keeps its claim in `<id>.lock` beside the transcript,
with the holder's host, operating-system pid, the time that process started
and its Erlang pid. A VM that halts or is killed leaves the file behind, and
the next claim takes it over only when the holder is provably gone: no
process has that pid, or the one that has it started after the claim. A
holder on another host cannot be checked, so it is refused; delete the lock
file once you know that process is gone.

The JSONL store also keeps transcripts private on macOS and Linux. Each
`<id>.jsonl` is created `0600` before its first line, and one an earlier
build left more open is tightened at its next write. A sessions directory the
store creates is `0700`. A directory that already exists keeps its mode,
because it may be shared (`/tmp`, a project, a volume).

### Large repeated values

A session writes each large value its request and harness snapshots repeat
(the system prompt, the tool schemas and catalog) once per transcript, and a
reference after that (`Lemieux.Transcript.Dedup`). A store sees those
references in what `append/3` is given and returns them from `read/2`; a
resumed session and `Lemieux.Store.JSONL` put the values back, and a host that
reads its own store's entries directly calls `Lemieux.Transcript.expand/1`
first, or starts sessions with `transcript_dedup: false`. `evidence: :digests`
keeps request snapshots' digests and sizes without the prompt and schemas, and
`evidence: :off` also writes no harness snapshots or run evidence.

See `Lemieux.Store` and [Transcript compatibility](transcript-compatibility.md).

### Resuming, forking, replaying

All three are reads over the stored entries, which is why the transcript is
append-only and why compaction appends rather than rewrites.

```elixir
{:ok, session} =
  Lemieux.resume_session(
    supervisor: MyApp.Agents,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: store,
    resume: id
  )

{:ok, new_id} = Lemieux.Transcript.fork(store, id, at_entry_id)
```

A resumed session takes its conversation configuration (model, system prompt,
tool set, disabled names, MCP servers, generation parameters and reasoning
effort) from the transcript, not from your defaults. That is what makes
"resume continues exactly where it left off" checkable rather than
approximate. Host authority is different: pass `tool_profile` again after the
current tenant policy authorizes the resume; recorded profile evidence never
grants capabilities by itself. Pass a conversation option explicitly to
override it.

## Tools

`Lemieux.Tools.default/0` is read, write, edit and bash. The configured
`Lemieux.Tools.WebSearch.new/1` and `Lemieux.Tools.WebFetch.new/1` are
deliberately absent from that default; a host adds them to `:tools` only when
it has opted in. Commands inherit the VM's environment, with the changes a
host records through `Lemieux.Environment.Inherited`, less what the
environment's credential policy withholds
([Decide what tools may see](#5-decide-what-tools-may-see)). Your own tool is
a module implementing `Lemieux.Tool`:

```elixir
defmodule MyApp.Tools.Deploy do
  @behaviour Lemieux.Tool

  @impl true
  def name, do: "deploy"

  @impl true
  def description, do: "Deploys the current branch to staging."

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def run(_arguments, context), do: {:ok, MyApp.Deployer.run(context.cwd)}
end
```

Pass it in `:tools` alongside the defaults. It goes through the same dispatch,
hooks, transcript and error handling as everything else.

Legacy text-returning tools remain valid. A host integration that needs typed
audit or rendering data wraps its executor with `Lemieux.Tool.Descriptor` and
may return `Lemieux.Tool.Result`; the provider still reads only bounded model
text. A tool whose effect lives somewhere the harness cannot look (a message
sent, a ticket filed) declares `effects: %{"class" => "external"}` and may
leave a **receipt**, a record of the effect, with
`Lemieux.Tool.Receipt.record/2`, so a result lost to a crash is reported to
the model as unknown rather than as a failure to repeat.
See [Governed tool contracts](tool-contracts.md).

## MCP servers

```elixir
mcp_servers: [
  %{"name" => "github", "transport" => "stdio", "command" => "npx",
    "args" => ["-y", "@modelcontextprotocol/server-github"],
    "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}},
  %{"name" => "docs", "transport" => "http", "url" => "https://example.com/mcp"}
]
```

Their tools arrive named for the server (`github__create_issue`) and are
otherwise ordinary tools. `${VAR}` is expanded from the environment at connect
time and never before: the configuration is written into the transcript, and a
token expanded any earlier would be written with it.

A server that will not start costs its own tools and nothing else. A server
that offers prompts or resources and no tools still connects:
`Lemieux.Session.mcp_clients/2` lists every connected server with the
capabilities it declared, and `mcp_resources/2` and `mcp_resource/3` list and
read resources without handing pids to the caller. An explicit
`reconnect_mcp/2` may start a server's browser sign-in; startup never does
when the host passes `mcp_connect_opts: [interactive_auth: false]`.

Servers connect in the background, each in its own task, so a session answers
snapshots, `info/1` and cancels while a slow one starts. Each server's
progress arrives as `{:mcp_server, status}`, and `{:ready, %{mcp: statuses}}`
once all have settled. A prompt that arrives before then waits up to
`:mcp_grace_ms` (fifteen seconds from the session's start) for them, so its
request can name their tools, and goes without the rest after that; they join
the next request when they answer. `mcp_status/1`, `tool_status/1` and the
other catalog questions wait for startup connections to settle rather than
reporting a slow server as empty. A server that announces `tools/list_changed`
has its tools replaced for the next request.

`mcp_connect_opts: [interactive_auth: false]` makes a server that needs
somebody's OAuth consent settle as `:needs_auth`, with where to sign in under
`auth`, instead of waiting for a browser.

The default stdio transport starts a local Port. A sandboxing host must instead
pass `mcp_stdio_launcher`, a four-arity function receiving the unmodified
command, arguments, expanded environment map and effective working directory:

```elixir
mcp_stdio_launcher: fn command, args, env, cwd ->
  MyApp.Sandbox.open_mcp_port(command, args, env: env, cwd: cwd)
end
```

It returns `{:ok, port}`, `{:ok, %{port: port, close: close_fun}}`, or
`{:error, reason}`. The returned Port must deliver data and exit messages to
the calling MCP client process. The map form lets the host close the Port and
then escalate container or microVM termination when the supervised client
ends. The host owns binary resolution, environment allowlisting, mounts,
network policy and bounded stderr inside that callback; Lemieux owns protocol
framing and request deadlines. The launcher is executable authority and is
never persisted or restored, so it must be passed again on resume. Test an
integration with a real MCP request and response (for example `tools/list`),
not only process creation.

For servers behind OAuth, attach a `Lemieux.MCP.Auth`. The library does
discovery, registration, PKCE, the exchange, storage and refresh; the host
supplies the one thing a library cannot do honestly, which is open a browser
and bind a port. A host that cannot do that either, a server-side one, reads
a token store an operator filled in with `lmx`, which keeps its tokens in
`~/.lmx/mcp-credentials.json` (or the file `--credentials` or
`LMX_CREDENTIALS` names).

`Lemieux.MCP.Auth.Store.File` is the file-backed store: one JSON file, `0600`,
in a directory it creates `0700`. It is not encrypted; a host that needs more
implements `Lemieux.MCP.Auth.Store` over a keychain.

- `Store.File.new(path)` keeps tokens at `path`. `Store.File.default_path/0`,
  `~/.lemieux/credentials.json`, is there for a host that names no file of
  its own. `lmx` keeps its tokens in `~/.lmx/mcp-credentials.json` instead,
  and the first time it uses that store it **moves** an existing
  `~/.lemieux/credentials.json` into it. Another host on the same machine
  that relied on the default then finds the file gone and authorizes its
  servers again. Name a file of your own to avoid sharing one.
- `Store.File.new(path, migrate_from: old_path)` moves `old_path` to `path`
  on first use, and `Store.File.migrate/2` does it now. The old file is
  removed rather than kept as a copy. A target that already holds records,
  or will not parse, is left alone; an empty one is written over.
- `Store.File.create/1` makes an empty private store ahead of the first
  token, for a sandbox that can hide only paths that exist when it starts.

See `Lemieux.MCP` and `Lemieux.MCP.Auth`.

## Long conversations

The session tracks how full its context window is and summarises the elder part
when it fills. `Lemieux.Session.snapshot/1` reports the position, and a
`{:context, position}` event arrives once per prompt so a status line has
somewhere to come from without copying the whole transcript.

```elixir
%{context: %Lemieux.Context{tokens: t, window: w, fraction: f, spent: spent}} =
  Lemieux.Session.snapshot(session)
```

Compaction is configurable per session (`:compact_at`, `:keep`) and can be
asked for outright with `Lemieux.Session.compact/2`. It never destroys the
transcript: it appends an entry recording what was summarised, so a replay
still shows the whole conversation.

How it is done is a seam. `:compaction` takes a module implementing
`Lemieux.Compaction`, or `{module, state}`, and the session dispatches every
compaction call through it: where to cut, what a request carries after a
cut, what the summariser is asked, and how the summary is put in front of
later requests. The default is `Lemieux.Compaction` itself, which is also
where the behaviour is declared. What the option cannot change is *when*:
the threshold, `compact/2` and provider context-limit recovery stay in the
session, and all three fire only between turns, because a cut inside one
produces the request every provider rejects. The `:compaction` entry and the
`{:compacted, …}` event keep their shape whichever module wrote the summary,
and the option itself is never recorded.

The summary is prose unless `summary_sections: true` asks for four
structured sections, `open work`, `dependencies`, `decisions` and
`verification debt`, as a lighter remedy for a long run losing its
obligations. With it on, the summariser is told to end with those sections,
`Lemieux.Compaction.sections/1` reads them back, and both the `:compaction`
entry (`"sections"`) and the `{:compacted, %{sections:}}` event carry the
result: `nil` when the model ignored the instruction, which is how a host
running the experiment tells a structured summary from a prose one. It is off
by default until a paired workload shows it retains obligations better.

The `{:compacted, …}` event also carries `tokens: %{before:, after:}`: where
the window stood when the summariser was asked, and an apportioned estimate of
where the cut leaves it, or `nil` when nothing had measured it. The first is
taken in the last moment it can be: appending the compaction entry makes the
position unmeasured until the next response, so a front end cannot work it out
afterwards. The second is an estimate for the same reason, and hosts should
render it as one; `Lemieux.Context.compacted/4` is the same apportionment the
`/context` bands use.

If a provider reports a typed context-window overflow before emitting any
content, call, message or usage, the session may force one compaction and retry
the request. It never retries after partial output, never retries the retry,
and charges the compaction and second request through the ordinary cost gate.
Subscribers receive `{:context_recovery, %{action: :compact_and_retry,
reason: typed_reason}}` before that work begins. A refusal that states the
model's window (most do) sets the session's window from then on.

Automatic compaction plans against the model's window capped at
`:compaction_window_cap` (200,000 tokens), so a million-token model compacts
at 160,000 rather than 800,000. A window the provider reports serving, as a
local Ollama daemon does, replaces a looked-up one and caps a configured one.
When nobody knows the window, the session plans against
`:context_window_fallback` and says so once per model with
`{:context_window_unknown, %{model:, fallback:}}`: before that model's first
request, and again after a model change. A host that subscribes when it
prompts therefore hears it.

Two more events report a window too small to work in.
`{:context_window_small, %{model:, window:, overhead:, source:}}` arrives
once per model and window when the window leaves less than 8,192 tokens
beyond the session's own instructions and tools (`overhead`, estimated). When
those alone are over the compaction threshold, threshold compaction is not
tried, because no summary could get under it.
`{:compaction_ineffective, %{input_tokens:, threshold:, window:, retry_in:}}`
means the request built right after an automatic compaction was still over
the threshold: the summary made no room. The threshold then waits `retry_in`
requests (32) before trying again; `compact/2` still works, and a new window
or model resets it.

With no `:keep` or `:keep_recent_tokens`, the retained tail is 30% of that
window and never more than half of the conversation, which is what lets one
prompt followed by a long run of tool calls be compacted at all. Between
compactions, the output of old, large tool results is stubbed
(`:stub_tool_results`), a batch at a time so a prompt cache keeps its prefix.

The summarising request asks for low reasoning effort where the model offers
it and 8,192 output tokens, and is tried once more after a transient failure.
A failed summary does not turn the threshold off for the session: it waits
out a backoff of 2, 4, 8, 16 and then 32 requests, one step per consecutive
failure.

See `Lemieux.Context` and `Lemieux.Compaction`.

## Files attached to a prompt

A prompt containing `@lib/turn.ex` arrives with that file already in the
request. Your host does not have to do anything to get this: expansion happens
inside `Lemieux.Session`, after any `user_prompt` hook has allowed or rewritten
the text, and the result is persisted on the `:user` entry. The attachment
is a durable fact, so a resumed or forked session rebuilds the same request
rather than re-reading a working tree that has since moved.

Two consequences worth knowing when you embed:

- **Reads go through your `:environment`.** A host that pointed the session at
  a container or a remote workspace gets references resolved there, with the
  same working-directory confinement the `read` tool has. A reference that
  escapes it becomes an attachment saying so, which the model can see.
- **They are read in a task, not in the session process.** A slow or remote
  environment does not stop the session answering `snapshot/1`, `cancel/1` or
  `steer/2` while it reads.

An attached file rides on the `:user` entry, so it is re-sent on every request
for the rest of the conversation. `:keep_attachments` bounds that: the newest
N attachment-carrying prompts keep theirs and older ones carry a note naming
the file. `:all` turns the bound off:

```elixir
Lemieux.start_session(supervisor: MyApp.Agents, keep_attachments: :all, ...)
```

`Lemieux.Session.refresh/1` re-reads every file the conversation attached and,
for any that have changed, submits them as a new prompt. It never rewrites the
turn that carried the old version.

See `Lemieux.Reference` for the grammar, the budgets, and why a bare word like
`@spec` in a pasted snippet resolves to nothing.

## Testing your host

Use `Lemieux.Providers.Scripted`, which ships in the library rather than in
`test/support` precisely so embedders can use it. It replays a script and
records every request it was given, so a test can assert on the exact
conversation the loop built:

```elixir
provider =
  Lemieux.Providers.Scripted.new([
    Lemieux.Providers.Scripted.tool_call("1", "read", %{"path" => "a.ex"}),
    Lemieux.Providers.Scripted.complete("it says hello", fragments: ["it says ", "hello"])
  ])

{:ok, result} = Lemieux.Testing.prompt(session, "read a.ex")
assert result.stop_reason == :stop
assert Enum.any?(result.entries, &(&1.type == :tool_result))

assert [_first, %Lemieux.Request{entries: entries}] =
         Lemieux.Providers.Scripted.requests(provider)
```

Time is the other thing a test should own. A session's deadlines, approval
timeouts, MCP grace and retry backoff run on its `:clock`; hand it a
`Lemieux.Clock.Manual` and move time yourself, and a slow machine cannot make
a timeout fire early or late:

```elixir
clock = start_supervised!(Lemieux.Clock.Manual)
{:ok, session} = Lemieux.start_session(supervisor: MyApp.Agents, clock: clock, approval_timeout: 20, ...)
Lemieux.Clock.Manual.advance(clock, 20, settle: session)
```

No key, no network, milliseconds. Builders cover text/thinking fragments,
multiple calls, malformed arguments, typed 429/500/context errors and delays;
a delayed turn gives cancellation tests a deterministic in-flight request.
The builders describe the Provider contract rather than vendor SSE internals.

## What lemieux will not do to you

- It starts nothing until you mount it, registers no process outside the name
  you mount it under, and reads no `:lemieux` application environment.
  ReqLLM's own key configuration is consulted only to decide whether a
  personal default key from `api_key_defaults` applies. Its dependencies are
  not as quiet: `:req_llm`, `:websockex` and `:yamerl` start their own
  supervisors with your application, and `:req_llm` loads `./.env` unless you
  set `config :req_llm, load_dotenv: false`.
- It never references a host. There is no callback into your application
  except the ones you passed in.
- It takes no web and no database dependency, so it cannot drag either into
  your tree.
- It writes credentials nowhere except the store you gave it, and never into a
  transcript.

## Composition and diagnostics

### Start with the existing session API

Hosts can keep passing session options directly. No Lemieux process starts
until the host mounts the runtime, and no extension loader or terminal
dependency is required. A restricted host
keeps `tools: []`, supplies scoped `host_tools`, and owns its environment,
hooks, budgets and process lifecycle.
[Embedding Lemieux inside Ixway](ixway.md#embedding-lemieux-inside-ixway)
describes one such host.

For a coding host, the shipped recipe is ordinary data:

```elixir
recipe = Lemieux.Extensions.coding(model, provider, interactive: true)
recipe = Keyword.delete(recipe, :delegation)
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), Keyword.values(recipe))
Lemieux.start_session(supervisor: MyApp.Agents, provider: provider, model: model,
  store: store, harness: harness, max_requests: 20, environment: host_environment)
```

The CLI uses the same ordering. The **scout**, a read-only investigator the
model can delegate to, is on in the coding recipe; interactive questions
require `interactive: true`. Web access, workspace discovery, MCP and file
hooks require explicit specifications. Removing a recipe entry removes that
opinion; replacing it uses ordinary keyword-list operations. Mandatory host
constraints belong beside `harness:`.

### Diagnose and recover

```sh
lmx explain --config none --no-delegate > before.json
lmx explain --config none --explain-against before.json
lmx explain --no-user-extensions
```

Explanation output is versioned JSON. It includes local tool names, wrapper
layers, profile/disabled decisions, configured limits, strategy modules,
hook names, changed fields per extension and final host override names.
Prompt text, callbacks, private options, provider credentials and host state
are omitted. Unset harness limits say `session_default`. The CLI adds a
`diagnostics` object with runtime versions, model/route, credential presence,
configuration source names, MCP servers, and startup notices; it never emits
credential values. Remote MCP discovery and request hooks have not run, so
this is preparation evidence, not a claim about a sent request.
`Lemieux.Harness.explain/2` and `diff/2` offer the same view to embedders.

Selected extensions still execute trusted initialization code during
preparation. `--no-user-extensions` skips extensions selected by personal
config and CLI flags, without dropping host extensions, hooks or budgets.
It does not bypass a resumed session's requirement for a missing transforming
extension. Use an explicit replacement catalog to adopt a different tool
policy. `--config none` remains available for an invalid personal config.

### Compatibility and lifecycle

The supported composition surface is `Extension`, documented `Harness`
fields/helpers and the behaviours selected by those fields. Internal CLI
assembly and code-loading modules remain internal. Source API changes are
called out in the changelog and exercised by the package consumer. A
compiled extension bundle that records an extension API version loads on a
runtime with the same extension API version, the same OTP major version, and
an Elixir of the same major version that is the same as, or newer than, the
one it was built with. One built before API versions existed needs the exact
Lemieux, Elixir and OTP versions it was built with. Source API compatibility
is not a promise of a cross-version binary ABI. [Support](support.md) has
the upgrade procedure.

An extension's `describe/1` must return JSON-shaped data with string keys.
Only include public configuration; descriptions are durable provenance.
Invalid description shapes fail during assembly, and missing guard or
compaction callbacks fail during session initialization before admission or
model work. Callback implementation failures remain errors, not silent
fallbacks. Messages alone allow omitted sentences to inherit defaults.

`init/1` prepares immutable state and may read files. `apply/2` consumes that
state without I/O or starting resources. Host supervision owns services
needed by an extension, including cancellation and shutdown. Pass service
references privately through initialization. Repeated preparation is not a
resource lifecycle manager.

Resume applies the current host's code, options and authorization. CLI
ceilings are retained in the assembly record when omitted on resume; current
CLI settings and explicit host overrides win. An embedding host must
resupply its own ceilings. A changed extension digest or options is
observable provenance, not an automatic rollback or refusal.
Tool-transforming extensions must still be selected, unless the host supplies
an explicit replacement catalog. Order matters; reordering is a new
composition decision. No assumption of commutativity or arbitrary third-party
idempotence is made. Older records remain readable; unknown reconstruction
versions require an explicit replacement catalog. Request and spend ceilings
include history; resuming does not reset them. An explicit new ceiling is a
host decision about the whole session.

### Executable examples

The separate
[package consumer](https://github.com/houllette/lemieux/blob/main/test/package_consumer/lib/opinions.ex)
contains three executable examples: one sentence override, a decorated host
query tool, and a complete compaction strategy delegating the shared replay
rules. They compile using only the packaged API, without repository test
helpers. From a checkout, `scripts/check_package.sh` builds the Hex package,
compiles the consumer against it and runs its three phases (seed, resume,
tighten), each in a separate VM; the resume phase also compacts through the
example strategy and checks that earlier entries are unchanged, and the third
VM replays that summary.

For a local preparation baseline, run `mix lmx.harness.bench --iterations 30`.
It reports median/p95 preparation time, process deltas, catalog/schema size
and prepared-term size without making model calls. Compare on the same host
and toolchain; timings are not performance guarantees or token counts.
