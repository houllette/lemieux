# Extensions

Lemieux should work out of the box in every mode — as a library, as `lmx run`,
as the full-screen TUI — and any opinion a person dislikes
should be replaceable or extendable with their own Elixir code, without a
fork. The **harness** is everything a session starts from: its instructions,
tools, hooks, limits and strategies. An **extension** is a module that
receives the harness a session is about to start from and returns the
harness it should start from. `lmx` itself is the library plus a list of
extensions, and yours go through the same callback.

Start with [Your first extension](first-extension.md) for a complete runnable
project and offline test. This guide is the reference: the two moves an
extension makes, a worked example, the extensions `lmx` ships and which mode
applies which, and what the transcript records about them.
`Lemieux.Extension`, `Lemieux.Harness` and the modules under
`Lemieux.Extensions` carry the reasoning next to the code.
For help choosing between settings, skills, hooks, and native code, use
[Customizing Lemieux](customization.md).

Read [the harness](#the-harness) and [composition](#overload-and-extend) first.
Then use the [worked extension](#a-worked-extension),
[installation guide](#installing-an-extension-into-lmx), or
[recipes](#extension-recipes) for your next change.

## The harness

`Lemieux.Harness` is a struct holding every seam's current setting. Its
fields are `Lemieux.Session.start_link/1`'s options, one for one, with the
same names — `system`, `tools`, `host_tools`, `hooks`, `compaction`,
`messages`, `guard`, `mcp_servers`, `max_cost_usd` and the rest — plus the
few opinions a host with a screen reads (`theme`, `status_line`, `followups`,
`processing`, `skills`, `notices`, `workspace`) and `applied`, the provenance
described below.

A field left unset is omitted when the harness becomes options, so the
session applies its own default: the short default prompt, the four coding
tools, no budget, or on a resume whatever the transcript recorded.
Most fields use `nil` for absence. `system`, `compact_at` and
`reasoning_effort` use `:default` instead: explicit `nil` respectively
disables the prompt, disables threshold compaction, or clears an effort.
`Lemieux.Harness.session_options/1` is that conversion, and
`Lemieux.start_session/1` accepts the struct directly:

```elixir
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [MyApp.AuditedBash])

{:ok, session} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: provider,
    store: store,
    model: "anthropic:claude-sonnet-5",
    harness: harness,
    max_cost_usd: 4.00
  )
```

An option named in the keyword wins over the same field on the harness. The
harness is behaviour that arrived through code; the keyword is the host
speaking now, about this session. Provider, store, model, supervisor,
subscriber and working directory are not harness fields at all: they are
host authority. This is a composition boundary, not a security sandbox:
extensions run as trusted Elixir in the host VM.

For the CLI, explicit host constraints such as `hooks:`, `environment:`,
`tool_profile:` and budgets also win after assembly. Prompts, catalogs,
host tools, MCP servers and harness context are inputs extensions can compose
over; a final `Runtime.start/2` override can replace any of them.

## The contract

```elixir
defmodule Lemieux.Extension do
  @callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}   # optional
  @callback apply(harness :: Lemieux.Harness.t(), state) :: Lemieux.Harness.t()
  @callback describe(state) :: map()                                     # optional
end
```

`apply/2` is the one required callback and is pure: it may be called more
than once with the same state. `init/1` turns the options a host wrote into
that state and is where files are read and inputs validated; an extension
without one gets its options verbatim. `describe/1` is JSON-shaped
provenance for the transcript — a path, a digest, a count, never a
credential.

`Kernel.apply/2` is imported into every module, so a module defining
`apply/2` starts with `import Kernel, except: [apply: 2]`.

A host names extensions to `Lemieux.Harness.assemble/2` as a module or
`{module, opts}` and gets `{:ok, harness}` or `{:error, {module, reason}}`
when an `init/1` refuses. Refusing is the right answer for a file that does
not exist or a profile that fails validation: a session started without the
behaviour somebody asked for is worse than no session.

## Overload and extend

Two moves cover what an extension does:

- **Overload** is replacing a field. `%{harness | compaction: {MyCompaction, opts}}`
  swaps the summariser; `%{harness | system: my_prompt}` swaps the prompt.
  Whatever an earlier extension put there is gone.
- **Extend** is wrapping what is there. `Lemieux.Harness.update_tools/2` with
  `Lemieux.Tool.decorate/2` puts an audit around `bash` and leaves the other
  tools alone; `Lemieux.Harness.append_hooks/2` adds a policy beside the
  host's; `Lemieux.Harness.append_host_tools/2` adds a loader. Whatever was
  there is still there, underneath.

Both read the harness before writing it, so **order matters**. An extension
that wraps `bash` must come after the one that put `bash` in the catalog, and
one that replaces the catalog undoes every wrap before it. `assemble/2`
applies the list left to right and records the order.

## A worked extension

This composition example wraps `bash`, adds a policy hook, and adds a tool.
`MyApp.Policy`, `MyApp.Audit`, and `MyApp.Tools.Deploy` are application-specific
placeholders. For a complete project, use [hello](first-extension.md).

```elixir
defmodule MyApp.Audited do
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool

  @impl true
  def init(opts) do
    opts = case Keyword.fetch(opts, :config) do
      {:ok, %{"log" => log}} -> [log: log]
      {:ok, _config} -> []
      :error -> opts
    end

    case Keyword.fetch(opts, :log) do
      {:ok, log} -> {:ok, %{log: log}}
      :error -> {:error, "MyApp.Audited needs a log: path"}
    end
  end

  @impl true
  def apply(harness, %{log: log}) do
    harness
    # Extend: the same bash, with every command written to the log after it
    # runs. `digest:` names the wrapper in the tool's descriptor, so a
    # snapshot can tell an audited bash from a plain one.
    |> Harness.update_tools(fn tools ->
      Tool.decorate(tools, %{
        "bash" => &Tool.Override.new!(&1, digest: "audit-v1", after: audit(log))
      })
    end)
    # Extend: a policy beside whatever the host already attached. Appended
    # after the host's hooks, so the host's deny still comes first.
    |> Harness.append_hooks(before_tool_call: &MyApp.Policy.check/2)
    # Extend: one more tool in the catalog.
    |> Harness.update_tools(&(&1 ++ [MyApp.Tools.Deploy]))
  end

  @impl true
  def describe(%{log: log}), do: %{"log" => log}

  defp audit(log) do
    fn return, args, context ->
      MyApp.Audit.write(log, context.session_id, args["command"])
      return
    end
  end
end
```

`after` receives the wrapped tool's return verbatim — `{:stream, enumerable}`
included — and decides the result; `before` may rewrite the arguments or
refuse the call. `Lemieux.Tool.Override` documents both.

Applied by a library host:

```elixir
{:ok, harness} =
  Lemieux.Harness.assemble(Lemieux.Harness.new(hooks: [before_tool_call: &MyApp.Approval.ask/2]), [
    {MyApp.Audited, log: "/var/log/agents/#{tenant}.log"}
  ])

Lemieux.start_session(
  supervisor: MyApp.Agents,
  harness: harness,
  provider: provider,
  store: store,
  model: model
)
```

Applied by `lmx`, from a host that embeds the CLI:

```elixir
Lemieux.CLI.run(argv, extensions: [{MyApp.Audited, log: log}])
```

`extensions:` is applied after everything `lmx` adds except Jev compaction,
which is where a host can wrap what `lmx` did.

## What `lmx` ships, and which mode applies which

`lmx` is the library plus a list of these, applied through the same callback
as yours. `Lemieux.CLI.Runtime` holds the list; nothing else assembles a
session. The name in the third column is what `"disabled_extensions"` in
`~/.lmx/config.json` takes to leave one out; `lmx explain` reports the ones a
session would apply.

| Extension | What it does | Name | `lmx run` | TUI |
| --- | --- | --- | --- | --- |
| `Lemieux.Extensions.Hooks` | Command hooks from `--hooks FILE` and the config file's `"hooks"` | | when given | when given |
| `Lemieux.Extensions.Permissions` | The approval policy, when `--permission-mode` or `"permissions"` sets a mode; off by default | | when set | when set |
| `Lemieux.Extensions.MCP` | Servers from `--mcp-config FILE`, your `"mcp_servers"` and the repository's trusted `.mcp.json` | `mcp` | default | default |
| `Lemieux.Extensions.MCPDiscovery` | `mcp_discover`, which keeps a large MCP catalog out of the request until it is searched | `mcp_discovery` | with MCP | with MCP |
| `Lemieux.Extension.Profile` | The tuning in `--extension-profile FILE` | | flag | flag |
| `Lemieux.Extensions.Interactive` | `ask_user`, because somebody is attached | `interactive` | no | yes |
| `Lemieux.Extensions.Web` | `web_search`, guarded `web_fetch` and `research_check` with a configured Brave key; explicit web settings override | `web` | key or flag | key or flag |
| `Lemieux.Extensions.Elixir` | The `--elixir` profile: `elixir` alone, plus `ask_user` if it was there | `elixir` | flag | flag |
| `Lemieux.Extensions.Search` | `grep` and `glob` | `search` | new sessions | new sessions |
| `Lemieux.Extensions.ApplyPatch` | `apply_patch` in place of `edit`, for GPT-5-family models | `apply_patch` | new sessions | new sessions |
| `Lemieux.Extensions.Planning` | The `todo` plan ([Plans](workflows.md#session-plans)) | `planning` | new sessions | new sessions |
| `Lemieux.Extensions.Workspace` | Persona, instructions, memory, skills, plugins, the learned overlay | `workspace` | unless bare | yes |
| `Lemieux.Extensions.EnvironmentContext` | The date, platform, shell, directory and git state at the end of the prompt | `environment_context` | default | default |
| `Lemieux.Extensions.Verify` | The project's check after a turn that edited files ([Verify](workflows.md#verify-after-changes)) | `verify` | default | default |
| `Lemieux.Extensions.A2A` | The peers in `"a2a_peers"` ([A2A](a2a.md)) | `a2a` | when configured | when configured |
| `Lemieux.Extensions.Delegation` | The repository scout behind `delegate`, and its budgets ([Delegation](subagents.md)) | `delegation` | default | default |
| Yours, from `--extension`, `--extension-dir` or `"extensions"` | Whatever you built; see [Installing an extension into `lmx`](#installing-an-extension-into-lmx) | | flag | flag |
| `Lemieux.Extensions.Checkpoints` | Records what tools change, for `/undo`, `/rewind` and `/redo` ([Checkpoints](tool-contracts.md#checkpoints)) | `checkpoints` | default | default |
| `LemieuxJevCompaction` | Jev compaction, bundled with the `lmx` release ([Compaction](compaction.md#optional-jev-projection-before-compaction)) | `jev_compaction` | when a route is set | when a route is set |

"New sessions" means a session `lmx` is equipping a fresh catalog for: a
resumed session keeps the catalog its transcript recorded. `environment_context`,
`verify` and `checkpoints` need a personal state directory, so `--config none`
without `LMX_HOME` leaves them out, and an `--extension-profile` run gets
neither `environment_context` nor `verify`.

The order in the table is the order they apply: hooks and the policy that
reads what they decided, then servers, the interactive tool, the network
tools and the Elixir profile that narrows the catalog, then the tools `lmx`
adds to a fresh catalog, then the workspace layer over the result, then the
scout beside it, then what you loaded. A profile goes before the catalog
extensions so `ask_user` and the scout join its tools rather than being
replaced by them. Checkpoints come after your extensions, so the file tools
they wrap are the final ones. An embedding host's own `extensions:` apply
after all of these, and Jev compaction after everything else.

A library host applies none of them by default. Its session is the base
harness and whatever it assembles. `Lemieux.Extensions.coding/3` returns the
core of the same recipe as an editable keyword list,
`Lemieux.Extensions.Workspace` is how a host opts into the CLI's workspace
experience, and the others are one line each.

### A profile is a data-only extension

`Lemieux.Extension.Profile` implements the same behaviour with a JSON
document for code: `apply/2` sets the prompt, the catalog and its
descriptions, the budgets and the generation parameters. The model is host
authority, so it stays off the harness and a host reads it with
`Profile.model/1`. The experimental tuning lane described in
[Build and tune an agent extension](agent-extensions.md) — freeze, confirm,
export, through the `mix lemieux.extension.*` tasks — applies to any
extension; a profile is the one kind whose whole content is a document.

### Resume

A resumed session takes recorded settings when its host leaves them unset.
Composition needs more care: a serialized module list cannot preserve a tool
wrapper's functions, and composing over an already composed prompt appends
the same instructions twice.

The CLI records the original prompt and module catalog before workspace and
user transformations, then reapplies the currently selected extensions to
those inputs on resume. A missing extension that transformed or removed an
existing tool produces an actionable error. Supply it again, or explicitly
pass a replacement `:tools` catalog to adopt a new policy. Removing a purely
additive extension removes its tools. Current profiles, budgets and disabled
tools still apply. Runtime tool structs and callbacks must be supplied by
the current host; neither their state nor private initialization options are
serialized. The record never selects or loads executable code.

Library hosts can assemble afresh from their own canonical inputs and pass
the result to `resume_session/1`; the core does not implement the CLI's
reconstruction policy. A transcript without this record remains readable;
a lost wrapper then needs an explicit base catalog to rebuild.
Changing tools live clears the old reconstruction record so a later resume
does not replay a recipe for a catalog the person replaced.

## Installing an extension into `lmx`

An embedder adds a Mix dependency. The installed `lmx` is a sealed OTP
release with no `mix.exs` to add to, so it loads your extension from a
directory instead: you build the directory once, in a project of yours, and
select it by name. Two rules from the rest of this guide survive the trip.
**Configuration never names code** — the config file and the flag carry a
name, and the manifest that names a module lives inside a directory you
populated. **A repository never runs code because an agent noticed it** — a
directory inside a checkout is loaded only when you type its path, the same
trust decision `--hooks` asks for. `Lemieux.CLI.Extensions` carries the
reasoning; this is the shape.

### The directory

```text
~/.lmx/extensions/audit/
├── extension.json
└── lib/
    ├── my_app/ebin/…        the project's beams
    └── jason/ebin/…         a dependency the binary does not ship
```

`extension.json` is the manifest:

```json
{
  "schema_version": 1,
  "name": "audit",
  "module": "MyApp.Audit",
  "ebin": ["lib/my_app/ebin", "lib/jason/ebin"],
  "versions": {"lemieux": "0.8.0", "elixir": "1.20.2", "otp": "29"},
  "extension_api": 1,
  "options": {"log": "/var/log/agents.log"}
}
```

- `name` is the directory's name: letters, digits, `-` and `_`.
- `module` is the `Lemieux.Extension` to apply.
- `ebin` lists compiled directories, relative to the extension's own, that
  go on the code path. Alternatively `script` names one `.exs` file, compiled
  when the extension loads, for an extension small enough to be a file.
  Exactly one of the two.
- `versions` are what it was built against, and `extension_api` the
  `Lemieux.Extension.api_version/0` it was built for. A compiled bundle loads
  when its extension API and OTP major version match the binary's, and the
  Elixir it was built with has the same major version as the binary's and is
  no newer; a mismatch is refused at startup in a sentence naming both
  sides. A bundle without `extension_api` predates it and must match
  Lemieux, Elixir and OTP exactly.
  A script's `versions` names only Lemieux, as a version (its release line) or
  a requirement such as `"~> 0.8"`, since the script is compiled by the
  running binary.
- `options`, if present, is a JSON object passed to the module's `init/1` as
  `[config: map]`, string keys and all. Personal config's
  `"extension_options": {"audit": {...}}` is merged over it, key by key, and
  survives a rebuild that replaces the manifest.

`lmx extension list` reports each installed extension and whether this binary
would load it, from the manifests alone; `lmx extension new NAME` writes a
script extension to start from. `lmx explain --extension NAME` (or
`--extension-dir DIR`) loads it and prints, as JSON, the session it would
shape, its extensions and its tools among the rest, without a model call. It
exits with status 1 when two tools share a name, because a session refuses
to start with that catalog: an extension should add what `lmx` does not
already have.

From a source checkout without an installed `lmx`, every `lmx` command on
this page runs as `mise exec -- mix lmx` from the checkout.

Paths in the manifest must be canonical relative paths inside the directory
with no symlinked component; anything else is refused. So is a module the
code does not define, a module without `apply/2`, and a script that does not
compile. None of these is a skipped extension: you asked for it, and a
session without it is worse than none.

The loader puts code on the path and starts no application. The host owns
services and their supervision tree. Pass service references through private
initialization options. Repeated `init/1` is not a lifecycle manager and there
is no extension teardown callback; use a custom supervised host for service
dependencies. See [recipes](extensions.md#depend-on-a-supervised-service).

### Building the directory

In a Mix project that depends on `:lemieux` and defines the extension:

```sh
mix lmx.extension.build --name audit
# Built audit (MyApp.Audit) into /home/you/.lmx/extensions/audit
# Run it with:  lmx --extension-dir /home/you/.lmx/extensions/audit
# By name, when it is under /home/you/.lmx/extensions:  lmx --extension audit
```

The task compiles the project and copies its `ebin` plus the `ebin` of every
runtime dependency the binary does not already carry — the shipped set is
`:lemieux`'s own application tree, computed from the `.app` files rather
than listed. The directory is named after the project's application unless
`--name` names it, `--output DIR` writes elsewhere, and `--module` picks the
extension when the project defines more than one; otherwise the one module
that exports `apply/2` and declares `@behaviour Lemieux.Extension` is chosen.
A rebuild replaces the directory whole, so a dependency you dropped does not
linger. Without an `lmx` on your `PATH`, the two commands it prints start
with `mix lmx` instead, and a last line says that `mix lmx` runs from your
Lemieux checkout.

Dependencies with native code are refused: a `priv` holding a `.so`,
`.dylib` or `.dll`, or a dependency on `rustler`, `elixir_make` or
`rustler_precompiled`. The shipped runtime cannot load a NIF built against
another ERTS, and the failure that would produce is a crash on load. An
extension that needs one is a reason to build your own host from
[`dist/lmx`](https://github.com/houllette/lemieux/blob/main/dist/lmx/README.md)
— a Mix project with a path dependency on `lemieux`, an `Application` and a
native OTP release; add your dependency and `extensions: [MyApp.Audit]` to
the host call and you have a binary identical to `lmx` plus your code.

### Selecting it

```sh
lmx --extension audit                 # ~/.lmx/extensions/audit, repeatable
lmx --extension-dir ./tools/audit     # any directory, repeatable
```

`"extensions": ["audit"]` in `~/.lmx/config.json` is the persistent form of
`--extension` — names only, never paths, never modules. The personal root is
`~/.lmx/extensions`, or `$LMX_EXTENSIONS_DIR` (a blank value counts as
unset). Loaded extensions apply after everything `lmx` ships except
checkpoints and Jev compaction ([the table above](#what-lmx-ships-and-which-mode-applies-which)),
and before an embedding host's `extensions:`, in the order given: the
config's names first, then the flags as typed. Both hosts — `lmx run`
and the TUI — load them, because both assemble through
`Lemieux.CLI.Runtime`. `--no-user-extensions` ignores the configured and
typed ones for a run.

`--extension-dir` is the only way a project-level directory runs. Nothing
looks for `.lmx/extensions/` in a checkout: opening an unfamiliar repository
must not execute its setup, and the flag is where you say you have read it.

## Provenance

A loaded extension is recorded twice. `harness_context["extensions"]["loaded"]`
says what was loaded, from where, and which build: the name, the directory,
the manifest's SHA-256, and for the `ebin` form three facts about the beams
it carries — `module_digest`, the md5 of the extension module's own beam;
`beam_count`; and `beams_sha256`, one SHA-256 over every `Module:md5` pair
in the directories, sorted (`script` and `script_sha256` for the script
form). `module_digest` matches the digest `assemble/2` records for it under
`"applied"`, described next, so the two lists can be read against each
other and a transcript names the exact build that shaped it; `beams_sha256`
changes when any dependency it brought along changed, without a snapshot
that every request carries growing by a line per module of every
dependency.

```json
"loaded": [
  {"name": "audit", "directory": "/home/me/.lmx/extensions/audit",
   "module": "MyApp.Audit", "manifest_sha256": "…",
   "ebin": ["lib/my_app/ebin", "lib/jason/ebin"],
   "module_digest": "b7e4…", "beam_count": 41, "beams_sha256": "…"}
]
```

`assemble/2` records, for each extension it applied and in order, the
module, the md5 of its compiled code and whatever `describe/1` returned:

```json
"extensions": {
  "session_profile": {"profile_sha256": "…", "kind": "session_extension"},
  "applied": [
    {"module": "Lemieux.Extensions.Interactive", "digest": "3f2a…", "options": {}},
    {"module": "Lemieux.Extensions.Workspace", "digest": "9c01…",
     "options": {"root": "/work/repo", "skills": 3, "overlay_sha256": null}},
    {"module": "MyApp.Audited", "digest": "b7e4…", "options": {"log": "/var/log/agents/acme.log"}}
  ]
}
```

That list lives in `harness_context["extensions"]["applied"]`, which the
transcript's `harness_snapshot` entries carry; every request entry names the
snapshot it was sent under. `lmx log SESSION --jsonl` prints both. A
transcript therefore says which code shaped the session that wrote it, and a
behaviour that changed between two runs can be traced to the extension whose
digest changed — or to the one that was applied in a different order.

## Extension recipes

Start with [Your first extension](first-extension.md). These recipes use the
same composition contract, without requiring the tuning/evaluation lane.

### Deny a tool call

Use a hook for execution policy. A library host can pass:

```elixir
hooks = [before_tool_call: fn call, _context ->
  if call.name == "bash", do: {:deny, "Shell access is disabled"}, else: :allow
end]
```

The [hook reference](hooks.md) documents argument shapes, rewrites, and pending
approvals. Mandatory host hooks belong beside `harness:` in start options; an
extension appends optional hooks with `Harness.append_hooks/2`.

### Wrap an existing tool

Use `Harness.update_tools/2` and `Tool.decorate/2` to wrap its implementation
without changing the other tools. The [worked audit extension](extensions.md#a-worked-extension)
shows this composition. Its `MyApp` modules are application-specific placeholders;
use the complete hello example for a runnable starting point.

Wrappers can receive streamed returns. Do not label a returned stream as a
completed side effect before it has been consumed. Keep evidence and errors true.

### Change one message or the compaction strategy

`Lemieux.Messages` permits individual sentence overrides. `Lemieux.Compaction`
requires a complete strategy whose cut, projection, and summary agree. See the
[executable package-consumer examples](https://github.com/houllette/lemieux/blob/main/test/package_consumer/lib/opinions.ex)
and [adoption guide](embedding.md#composition-and-diagnostics). These exercise only public APIs.

### Depend on a supervised service

The host starts and owns services. Pass references privately through extension
initialization. `init/1` may read and validate configuration, but preparation can
run repeatedly; it is not a resource lifecycle callback. `apply/2` is pure.
There is no extension teardown callback. An embedder mounts dependencies in its
application tree; a binary extension needing a service should use a custom
supervised host, rather than starting orphan processes during preparation.

A pure-Elixir dependency's `ebin` and `priv` can be included by
`mix lmx.extension.build`. Native dependencies need a custom binary build.
Conflicting dependency modules are refused; the loader provides neither package
isolation nor hot replacement. See [upgrading](support.md#upgrading-lemieux-and-extensions).

### Example projects

The [examples index](https://github.com/houllette/lemieux/blob/main/examples/README.md)
lists every example with its offline check and what a live run needs. Three
show the shapes an extension takes:

- [`hello`](https://github.com/houllette/lemieux/blob/main/examples/extensions/hello/README.md)
  is one deterministic tool in a Mix project, built into a bundle `lmx`
  loads. [Your first extension](first-extension.md) walks through it.
- [`planning`](https://github.com/houllette/lemieux/blob/main/examples/extensions/planning/README.md)
  is the smallest kind: one `.exs` script and an `extension.json`, no Mix
  project. It adds one pure tool, `plan_order`, which puts steps with
  dependencies in an order that works, and reports a dependency cycle, an
  unknown dependency or a repeated id as an error the model reads. It adds
  no `todo` tool of its own beside the plan `lmx` already keeps: two tools
  with one name stop a session before its first request. From the
  repository root, load it with
  `lmx --extension-dir examples/extensions/planning`, or check it first with
  `lmx explain --extension-dir examples/extensions/planning`, which makes no
  model call. The root test suite checks it.
- The [computer-use extension](https://github.com/houllette/lemieux/blob/main/examples/extensions/computer_use/README.md)
  is experimental: a separate Mix host with bounded web discovery, Jev
  classification (TypeSafe, billed) and headless browser actions through
  Wallaby. It demonstrates a composed tool inheriting the current host's
  policy for inner fetches and browser input. Its browser dependencies and
  lifecycle remain outside the core application. Its page-observation design
  and parts of its browser script are adapted from the MIT-licensed
  jev-ultrafast project; its `NOTICE` file carries that license.

The [Jev compaction extension](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/jev_compaction/README.md)
lives in `dist/lmx/extensions/jev_compaction` and ships inside the `lmx`
release; it is part of `lmx`, not an example. It attaches at
`prepare_next_turn` when a Jev route is configured and shortens selected old
read results in the outgoing request before summary compaction checks the
context window and price tier;
[Compaction](compaction.md#optional-jev-projection-before-compaction) says
what it sends and how to turn it off.

## Composition, restoration and trusted code

The composition contract is `Lemieux.Extension`, documented `Lemieux.Harness`
fields/helpers, and the selected message, guard and compaction behaviours.
Extensions assemble left to right; explicit session options beside `harness:`
remain host constraints. Nullable `system`, `compact_at` and `reasoning_effort`
use `:default` for absence, so an explicit `nil` keeps its public session meaning.
A custom progress guard cannot remove the session's independent turn ceiling.

Initialization may read files and prepare immutable private state. Composition
consumes that state without I/O or starting services. Host supervision owns
service lifetime and shutdown. Descriptions must be JSON-shaped public data
with string keys; they become durable provenance and must omit secrets.
Invalid strategies or descriptions fail preparation rather than silently
falling back. Individual omitted message callbacks inherit shipped defaults.

Resume uses current host code and authorization. The inert `harness_assembly`
record never chooses code to load or restores credentials/callbacks. Runtime
tools and private state come from the current host. Repeated CLI reconstruction
does not stack wrappers or append prompt additions again; a missing transforming
extension requires an explicit replacement catalog. Old reconstruction versions
may also require that catalog. Historical request/spend usage remains cumulative.

Native bundles execute trusted code in a shared BEAM VM. Module checks and
serialized loading prevent accidental collisions, including incompatible shared
helpers. They do not provide dependency isolation, a sandbox or hot replacement.
Conflicting bundles require compatible dependencies and a fresh VM. Binary
bundles require a matching extension API and OTP major version, and must be
built with an Elixir of the running one's major version and no newer.
[Composition and diagnostics](embedding.md#composition-and-diagnostics)
includes executable package-consumer and native smoke checks.
