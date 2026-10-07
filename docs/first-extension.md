# Your first extension

An extension packages changes to a session's harness: its prompt, tools,
hooks or strategies. It is trusted Elixir code. You do not need model tuning,
benchmarks, a plugin marketplace or a new agent loop to write one.

If you are deciding between saved settings, instructions, hooks and code,
start with [Customizing Lemieux](customization.md). This tutorial takes the
native-code path and adds a tool you can test without a provider key.

The `lmx` terminal UI includes `/create-extension` for guided implementation
with its usual coding tools. Open `lmx` (or `mise exec -- mix lmx` from a
source checkout), then type `/create-extension Add a tool that ...`. It also
includes `/evaluate-extension` for a bounded comparison once the code works.
These skills do not change the selected model or the session's budget, and
personal or project skills with the same names override the bundled ones.

## Choose the smallest seam

| Your change | Use |
| --- | --- |
| A capability the model can call | `Lemieux.Tool` |
| Approve, deny or observe execution | [Hooks](hooks.md) |
| Package prompt, tools and policy together | `Lemieux.Extension` |
| Store supported session settings as JSON | `Lemieux.Extension.Profile` |
| Own a multi-stage task | `Lemieux.Agent` (experimental) |
| Reusable model instructions | An Agent Skill |

Profiles are data; tools and extensions are code. An agent owns a whole task,
and that API is experimental: it may change in any 0.x release. Plugin bundles
are a separate format, from the Claude Code ecosystem. See the
[extension reference](extensions.md).

## Run the complete example

The [hello example](https://github.com/houllette/lemieux/blob/main/examples/extensions/hello/README.md)
adds `word_count`, a deterministic tool with no file or network effects. From
the root of a Lemieux checkout:

```sh
export LEMIEUX_EXTENSION_BASE="$PWD"
cd examples/extensions/hello
mise exec -- mix deps.get
mise exec -- mix test
```

No provider key is needed. The tests drive a real Lemieux session with
scripted model responses and check that the tool's result reaches the
transcript. `LEMIEUX_EXTENSION_BASE` points the example at your checkout. For
a project of your own, copy the directory and replace the `lemieux()`
dependency in its `mix.exs` with `{:lemieux, "~> 0.9"}` from Hex.

Read the complete [implementation](https://github.com/houllette/lemieux/blob/main/examples/extensions/hello/lib/hello_extension.ex):

- `init/1` validates options and returns immutable state. It accepts keyword
  options from a Mix host, or `[config: map]` from a CLI manifest.
- `apply/2` appends instructions and adds the tool. It does no I/O and starts
  no processes. Extensions apply left to right, so a later replacement can
  undo an earlier addition.
- `describe/1` returns public, JSON-shaped provenance, never credentials.
- The tool defines its name, description, JSON schema and `run/2`. Errors
  are ordinary results returned to the model. Its read-only and parallel-safe
  claims are explicit, and true for this tool.

A library host selects it with:

```elixir
{:ok, harness} = Lemieux.Harness.assemble(
  Lemieux.Harness.new(), [{HelloExtension, note: "Use word_count for exact counts."}])
# Pass harness: harness to Lemieux.start_session/1.
```

See [First embedded agent](first-embedded-agent.md) for the supervisor,
provider, store, session and cleanup around that call. Host options given
beside `harness:` win over extensions, including budgets and approval hooks.

## Install into lmx

From the example's directory, build it into a bundle `lmx` loads:

```sh
mise exec -- mix lmx.extension.build --name hello
lmx explain --extension hello
lmx --extension hello --max-requests 5
```

Without an installed `lmx`, run the last two from the checkout's root as
`mise exec -- mix lmx explain --extension hello` and
`mise exec -- mix lmx --extension hello --max-requests 5`; the build prints
the command to use. Ask `Count the words in one two three using word_count`.
That last command uses your API account. `explain` checks that the extension
loads and shows the tool catalog without a model request, though it still runs
the extension's trusted initialization.

The build writes `~/.lmx/extensions/hello/extension.json` and the compiled
code, and records the extension API it was built for
(`Lemieux.Extension.api_version/0`). `lmx` loads such a bundle when the
extension API is the same, the OTP major version is the same, and the Elixir
it was built with has the same major version and is no newer than the one
`lmx` runs. `lmx explain` prints the Lemieux, Elixir and OTP versions it runs,
and a checkout of the release your `lmx` came from pins the toolchain that
release was built with (`mise install` sets it up). A Lemieux patch release
or a newer Elixir in `lmx` needs no rebuild; a different OTP major version or
extension API does, and the loader says which in a sentence naming both
sides. A bundle built against a Lemieux from before
the extension API version existed records none, and loads only into an `lmx`
with exactly the same Lemieux, Elixir and OTP versions.

Configure the installed extension in your personal config rather than in the
bundle, because a rebuild replaces the bundle's manifest:

```json
"extension_options": {"hello": {"note": "Use word_count for exact counts."}}
```

These are merged over the manifest's own `options`. Save
`"extensions": ["hello"]` in your personal config to load it every time. For a
bundle in another directory, use `--extension-dir PATH`; extension folders
inside a repository are never loaded on their own.

### A script extension instead

An extension small enough for one file needs no Mix project and no rebuild
after an upgrade. `lmx extension new NAME` writes a directory with an
`extension.json` and one `.exs` file, which the running `lmx` compiles when it
loads it. Its manifest names only the Lemieux it was written for, as a version
(`"0.9.0"`, meaning that release line) or a requirement:

```json
{"schema_version": 1, "name": "planning", "module": "LemieuxPlanningExample",
 "script": "planning.exs", "versions": {"lemieux": "~> 0.9"}}
```

[`examples/extensions/planning`](https://github.com/houllette/lemieux/blob/main/examples/extensions/planning/README.md)
is one. It adds `plan_order`, a deterministic tool that puts steps with
dependencies in an order that works, and touches no files, network or model.
`lmx explain --extension-dir examples/extensions/planning` lists it without a
model call, and `lmx --extension-dir examples/extensions/planning` opens the
terminal UI with it. The example adds a tool `lmx` does not already have,
deliberately: two tools with the same name stop a session before its first
request.

For a capability that already exists as a service, an MCP server needs no
Elixir at all. For somewhere new to send a session's requests — a gateway or
a server of your own — a script can register a **model route** instead of
shaping the harness; [Adding a model route](extensions.md#adding-a-model-route)
and the [`relay` example](https://github.com/houllette/lemieux/blob/main/examples/extensions/relay/README.md)
show that form.

## Resume, remove and upgrade

`lmx --resume SESSION --extension hello` reapplies the current code to the
recorded inputs. To stop using an extension, stop selecting it and remove its
name from your personal config. A transforming extension can be required to
rebuild a resumed tool catalog; `--no-user-extensions` is for recovering a
startup, not a way around that requirement. See the
[upgrade guide](support.md#upgrading-lemieux-and-extensions).

`extension.json` is the manifest of a **loadable CLI bundle**.
`lemieux-extension.json` is an **export and evaluation source** manifest and
cannot be passed to the CLI loader. The hello example only needs the former,
which the build command writes. Dependencies with native code need a custom
host build.

## Add more behaviour

[Extension recipes](extensions.md#extension-recipes) covers wrapping a tool,
policy hooks and supervised dependencies.
[Agent development and tuning](agent-extensions.md) is an experimental next
step once you understand the implementation and its tests.
