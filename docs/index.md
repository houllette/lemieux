# Lemieux and lmx

**An open-source coding agent you can take apart: a terminal app (lmx), and the Elixir runtime underneath it (Lemieux).**

`lmx` is a coding agent for your terminal. It reads your code, edits files,
runs commands and checks its work with your project's own tests, on the model
you choose: any provider ReqLLM supports, or a local model in Ollama.
[First session with lmx](getting-started.md) installs it with one command.

Lemieux is the Elixir library underneath. It runs the model/tool loop itself
and records every session as an append-only transcript that you can resume,
fork and replay. Your application chooses the tools, policy, storage and
budgets. Add it to `mix.exs`:

```elixir
def deps do
  [{:lemieux, "~> 0.9"}]
end
```

Adding the dependency starts no Lemieux processes: mount
`{Lemieux.Supervisor, name: MyApp.Agents}` in your supervision tree, then
follow [First embedded agent](first-embedded-agent.md). Its dependencies do
start with your application, and ReqLLM loads `./.env` at boot unless you set
`config :req_llm, load_dotenv: false`
([For library hosts](../SECURITY.md#for-library-hosts)). Lemieux needs Elixir
1.19 or newer on Erlang/OTP 27 or newer.

## Choose a learning path

Follow the path that matches what you want to do. The tutorials give you a
working session first; the references explain the options when you need them.

| Goal | Read in order |
| --- | --- |
| Use the coding agent | [First session with lmx](getting-started.md) → [Everyday use](everyday.md) → [Configuration](configuration.md) |
| Run it from scripts or CI | [First session with lmx](getting-started.md) → [One-shot commands](cli.md#one-shot-command) → [Session limits](cli.md#session-limits) |
| Embed an agent in an Elixir application | [First embedded agent](first-embedded-agent.md) → [Embedding Lemieux](embedding.md) → [Hooks and policy](hooks.md) |
| Change prompts, tools or the interface | [Customizing Lemieux](customization.md) → [Your first extension](first-extension.md) → [Extensions](extensions.md) |
| Understand the design first | [Why Lemieux](why-lemieux.md) → [Transcript compatibility](transcript-compatibility.md) |

The embedded tutorial runs without an API key. A real model needs a
provider's API key, or a local model in Ollama. The
[examples](https://github.com/houllette/lemieux/blob/main/examples/README.md)
are runnable agents and extensions, each with a check that runs offline.

## Words you will meet

| Term | Meaning |
| --- | --- |
| **Host** | The program that runs Lemieux sessions: `lmx`, or your application. It supplies credentials, storage, where tools run, and policy. |
| **Session** | One conversation with the agent: a supervised process that runs the model/tool loop and records what happens. A session can take more than one prompt. |
| **Transcript** | A session's append-only record: every prompt, model request, answer and tool result. Resume, inspection, replay and fork all read it. |
| **Harness** | Everything a session runs with besides the model: instructions, tools, hooks, limits and strategies (`Lemieux.Harness`). |
| **Extension** | Trusted Elixir code that changes a harness before a session starts: it adds a tool, a hook or instructions, or replaces a strategy. |
| **Profile** | A data-only extension: a JSON document that selects supported session options and known tools, and runs no code (`Lemieux.Extension.Profile`). |
| **Hook** | A function or command that runs at a named point, such as before a tool call, and can allow, deny, rewrite or observe what happens there. |
| **Steer** | A message you send while the agent works. It reaches the model with its next request. |
| **Checkpoint** | What `lmx` saves so `/undo` can put files back: each file's contents before a file tool changed it and, in a git repository, snapshots around each command, the project check `lmx` runs after edits included. |
| **Receipt** | In the terminal UI, the line a tool call is drawn as (`Ran mix test`, `Edited lib/x.ex (+3 -1)`). In the library, the record a tool makes once a remote side has acknowledged its effect, so a lost result is reported as unknown rather than failed. |
| **Scout** | The read-only helper session `lmx` can hand a question to through its `delegate` tool. It reads with `read`, `grep` and `glob` under its own budget, and `--no-delegate` turns it off. |
| **Overlay** | A learned harness overlay: a JSON file, made by the experimental harness-learning tools, that adds system-prompt text. Only your own `~/.lmx/harness.json` may also re-describe tools, and `lmx` names a repository's `.lmx/harness.json` every time it applies one. |
| **System One** | A kind of model that answers typed questions about a state with calibrated probabilities instead of generating text, over `POST /v1/systemone`. TypeSafe's Jev is one; open ones (Cloudflare's Clef, Bespoke Labs' Nimble, Laya) run on your own machine. `lmx` bundles an extension that asks one which old file reads a conversation still needs, to shorten requests; it sends nothing until you configure a provider. See [what it sends](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md). |

## Using lmx

- [First session with lmx](getting-started.md): install, connect a model
  (hosted or local), and run a first prompt.
- [Everyday use](everyday.md): steering, approvals, undo, scripts and
  resuming.
- [CLI commands and keys](cli.md): interactive and headless commands, output
  formats and exit statuses.
- [Configuration](configuration.md): saved settings, the defaults `lmx` turns
  on, workspace discovery, instructions, skills, plugins and system prompts.
- [Desktop launchers and Omarchy](desktop.md): the application launcher
  entry, Omarchy keybindings and menus, and how launchers start `lmx`.
- [Trust model](../SECURITY.md#what-lmx-trusts-by-default): what runs without
  asking, what is guarded, and the opt-ins (permissions, sandbox, hooks).
- [Troubleshooting](troubleshooting.md): diagnosis and recovery.

## Embedding Lemieux

- [First embedded agent](first-embedded-agent.md): a complete session without
  a key, then a real model.
- [Embedding](embedding.md): lifecycle, the session API, composition
  diagnostics and host examples.
- [Transcripts](transcript-compatibility.md): durable records, reconstruction
  and compatibility boundaries.
- [Telemetry](telemetry.md): lifecycle events, correlation, redaction and
  OpenTelemetry.

For API details, start with `Lemieux`, `Lemieux.Supervisor` and
`Lemieux.Session`. `Lemieux.run/2` handles one prompt and returns its result;
`Lemieux.start_session/1` and `Lemieux.Session.await/3` keep a session for
successive prompts.

## Customizing Lemieux

The [customization guide](customization.md) helps you choose between settings,
model instructions, hooks, tools and Elixir extensions.

- [Your first extension](first-extension.md): a tested tool, installed into
  `lmx`.
- [Extensions](extensions.md): composition, recipes, installation and
  restoration.
- [Governed tools](tool-contracts.md): the built-in tools, descriptors,
  effects, receipts, attachments, checkpoints and background commands.
- [Hooks](hooks.md): approval, permissions, Claude Code compatibility and host
  policy.
- [Compaction](compaction.md): retained context, summary strategies and
  price-aware preflight.
- [Plans, goals and workflows](workflows.md): the `todo` plan, verification
  after edits, host-verified goals, and the experimental checkpointed
  composition.
- [Delegated investigations](subagents.md): the scout's authority, budgets,
  deadlines and evaluation gate.
- [Customizing the terminal UI](terminal-ui.md): themes, keys, layout, status,
  receipts, slash commands, and tests without a terminal.

The main extension APIs are `Lemieux.Harness`, `Lemieux.Extension`,
`Lemieux.Tool` and `Lemieux.Hooks`. Their module docs describe the contracts
behind the examples.

## Integrations

- [Providers](providers.md): ReqLLM routes, model discovery, streaming,
  failures, caching and accounting.
- [Ixway](ixway.md): optional inference gateway routing.
- [MCP](mcp.md): remote tools, prompts, resources, trust and authentication.
- [Web search and page fetch](web-tools.md): research tools and their network
  and accounting boundaries.
- [Agent-to-agent communication](a2a.md): configured peers and read-only
  services.

## Releases and support

- [Support and upgrades](support.md): supported surfaces, compatibility,
  extension rebuilds and recovery.
- [Installing and updating lmx](releases.md): installation, verifying a
  download, updates and rollback.
- [Roadmap](roadmap.md): what comes next.
- [Changelog](../CHANGELOG.md): what changed in each release.
- [Contributing](../CONTRIBUTING.md), [Security](../SECURITY.md) and
  [License](../LICENSE).

## Experimental: learning and evaluation

**Experimental.** These tools may change in any 0.x release. They are optional
next steps once you have a working agent or extension, and nothing above
depends on them.

- [Agent development and tuning](agent-extensions.md): build, compare, confirm
  and export one implementation across interfaces.
- [Reflection and feedback](reflection.md): review a run, capture corrections,
  curate cases and version durable assets.
- [Harness-learning contracts](harness-learning.md): evidence, discovery and
  standalone operation.
- [Benchmarking](benchmarking.md): paired methodology, accounting and report
  interpretation.
- [Evaluation gates](evaluations.md): release, provider, dependency and prompt
  gates.
- [Hosted harness learning](host-integration.md): how Lemieux, Ixway and an
  orchestrating host divide the work of adopting learned harness changes.
- [Cross-system acceptance](acceptance.md): the end-to-end acceptance
  procedure for a deployment of Lemieux, Ixway and an orchestrating host.

Use **Modules** in the sidebar for API contracts and **Mix Tasks** for
development commands.
