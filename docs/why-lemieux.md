# Why Lemieux

Lemieux is the Elixir runtime behind the `lmx` coding agent. It owns the loop
that sends the conversation to a model, runs the tool calls the model asks for,
records the results, and decides whether another model turn is needed.

That sounds like an implementation detail until you want to steer a running
agent, enforce a budget before the next request, resume on a different model,
audit which tools were offered, or fork a conversation from an older turn.
Each of those needs the harness (the loop and everything it runs with) to own
the state. Terminal output scraped from a vendor CLI is not enough to rebuild
it afterwards.

## The short version

Lemieux combines four ideas:

1. **Few default tools.** The library's defaults are four tools (read, write,
   edit and bash), which are enough for a capable coding model and keep
   every request's schema overhead low. `lmx` adds more, as extensions you
   can turn off.
2. **A provider-neutral loop.** `req_llm` owns vendor protocols; Lemieux owns
   turns, tools, policy and transcripts.
3. **An append-only transcript.** Resume, inspection, request replay and fork
   are ordinary reads over data Lemieux wrote.
4. **OTP as the control plane.** Sessions, provider work, tools, approvals,
   questions, steering and subscribers are processes and messages rather than
   terminal conventions.

`lmx` is what most people meet first, and the library is what it is built
from. `lmx` is one host of that library: an Elixir application can mount the
same supervisor and supply its own store, tools, environment, approval policy
and user interface, through the same public API `lmx` uses.

## What came from other harnesses

Lemieux did not start from the assumption that every difference should be
invented locally. The initial design studied [Pi](https://github.com/earendil-works/pi),
its Python port [tau](https://github.com/huggingface/tau),
[Codex](https://github.com/openai/codex),
[Claude Code](https://github.com/anthropics/claude-code),
[Gemini CLI](https://github.com/google-gemini/gemini-cli)'s hook vocabulary,
and the experience of driving vendor CLIs as subprocesses. The useful parts
were adopted at their natural layer.

| Source | Lesson adopted in Lemieux | Where Lemieux differs |
| --- | --- | --- |
| Pi and tau | A readable native loop; four default tools; exact-string edit; a compact system prompt; JSONL sessions; resume and branch; before and after tool hooks | Lemieux adds asynchronous, auditable approvals, `ask_user`, supervised concurrent tools, an injectable environment, and control-plane events for hosts |
| Codex | A sparse tool catalog is viable; shell composition can replace a permanent schema for every convenience operation. The `apply_patch` tool follows Codex's patch format and matching (`codex-rs/apply-patch`, Apache-2.0) | Lemieux keeps explicit read, write and edit tools for predictable file semantics, and stays provider-neutral instead of tying the loop to one model service |
| Claude Code | Strong interactive ergonomics; repository instructions; Agent Skills; useful hook lifecycle names; a plugin ecosystem | Compatibility is selective: Lemieux reads `CLAUDE.md`, Agent Skills, slash commands, `.claude/agents` (as read-only helpers), a Claude Code hooks file you name, and a selected plugin's skills, commands, agents, hooks and MCP servers, within the subset in the [compatibility table](configuration.md#compatibility-and-trust-boundary). It never runs a repository's hooks on its own or inherits a large global tool catalog |
| Gemini CLI | Portable hook concepts and event-name aliases reduce migration friction | Lemieux maps aliases onto one smaller hook contract instead of implementing a second event system |
| Existing CLI wrappers | A streaming terminal experience is genuinely useful | Lemieux runs the loop natively, because wrapping a CLI loses steering, exact accounting, owned transcripts and policy control |
| `req_llm` | Provider authentication, model catalogs, streaming, tool-call normalization, caching, usage and thinking-block continuity are a fast-moving shared problem | It is the provider seam, not the agent runtime. Lemieux does not adopt a larger agent framework around the loop |

The phrase used during the design was **"Pi above the seam, `req_llm` at the
seam."** Keep the security-critical loop small enough to audit; do not pretend
multi-provider streaming is a small, stable problem worth reimplementing.

## Acknowledgements

The designs of [Alloy](https://github.com/alloy-ex/alloy),
[Ash AI](https://github.com/ash-project/ash_ai),
[Whisperer](https://github.com/Monitor-Lizzard/whisperer),
[Sagents](https://github.com/sagents-ai/sagents),
[Legion](https://github.com/software-mansion/legion),
[LangChain](https://github.com/brainlid/langchain),
[Jido](https://github.com/agentjido/jido) and
[ReqLLM](https://hex.pm/packages/req_llm) informed Lemieux's retry,
tool-feedback, telemetry, receipt and testing boundaries.
[beamcore](https://github.com/beamcore/agent) and
[ex_athena](https://github.com/udin-io/ex_athena) informed bounded evaluation,
reference attachment and terminal scrollback. No comparator's source code is
vendored.

The [MCP guide](mcp.md#oauth-ownership-and-security) explains OAuth ownership;
the [harness-learning contracts](harness-learning.md) (experimental) define
discovery and independent confirmation.

## One turn through Lemieux

A normal coding turn makes the ownership boundary concrete:

1. The host appends the user's prompt to its `Lemieux.Store`.
2. The session takes any waiting steering messages and prepares a
   provider-neutral request from the effective system prompt, transcript
   entries, model, tools and parameters.
3. A `prepare_next_turn` hook may rewrite or deny that request. Lemieux checks
   the cost gate before sending it and stores a canonical snapshot of the
   request.
4. `req_llm` streams provider events back. Lemieux sends text and thinking
   deltas to subscribers while assembling one durable assistant entry.
5. Tool calls pass through before-tool hooks. A hook may allow, deny or
   rewrite a call, or park it for asynchronous approval.
6. Allowed tools run as supervised work through the configured
   `Lemieux.Environment`. Their output can be watched as it arrives; final
   results and durations are appended to the transcript.
7. If tools ran, a question was answered, steering arrived, or a stop hook
   asks for more work, the next request starts from the newly durable state.
8. Otherwise the session becomes idle, and the same process is ready for
   another prompt.

The session's mailbox stays available for snapshots, cancellation, steering,
approval decisions and subscriber management while effectful work runs. That
is the practical benefit of the BEAM design, not merely that the loop is
written in Elixir.

## What is specifically Elixir about it

The BEAM is not a branding choice, or an excuse to put model logic in macros.
It changes the shape of the control plane:

- A session is a GenServer with one ordered transcript writer.
- Provider requests, tool calls, hook decisions and compaction run as
  supervised work rather than blocking the session's mailbox.
- Steering is a message queued for the next request boundary.
- A pending approval or question parks one call without freezing snapshots,
  cancellation or other independent calls.
- Several subscribers can watch future events directly; a Phoenix host may
  fan those messages into PubSub without making PubSub a core dependency.
- A host can replace the tool environment with a container, microVM, remote
  workspace or policy service while keeping provider credentials in the host
  VM.

OTP does **not** make arbitrary shell commands safe. Lemieux confines its file
tools to the workspace by path and makes the environment injectable, but the
default bash tool has the launching user's authority. Isolation and approval
policy remain host responsibilities.

## The transcript is the product boundary

Every durable entry has an id, a parent, a sequence number, a type, a
timestamp, a payload and a schema version. Ordinary conversation entries sit
beside control-plane facts:

- session configuration;
- canonical, provider-neutral request snapshots;
- approval requests and resolutions;
- assistant output and normalized usage;
- tool results and durations;
- compaction summaries and cut points;
- cancellation, errors and fork lineage.

This gives several properties you can see:

- `lmx log` works offline;
- resume rebuilds the conversation instead of handing a provider an opaque
  remote thread id;
- a session may resume with a different API route or model;
- safe forks refuse cuts inside unfinished tool waves;
- request replay can prove the canonical model, system text, entries, tools,
  schemas and safe parameters that Lemieux handed to `req_llm`.

Request replay is deliberately not presented as byte-for-byte HTTP replay.
Provider adapters and their versions own wire formats, and a future model call
is not deterministic. [Transcript compatibility](transcript-compatibility.md)
defines that boundary precisely.

## Why the defaults stay few

Every tool schema and every system-prompt rule is sent again with every
request. A global tool added for one workflow costs every unrelated session
tokens and model attention. Lemieux therefore separates mechanisms from
equipment:

- the library ships four general coding tools;
- interactive hosts add `ask_user`, because a person is present;
- MCP tools are added only when their server is configured;
- Agent Skills use progressive disclosure;
- an embedding host selects the tools each profile needs;
- `lmx` adds search, guarded page fetch and a passage checker when a Brave key
  is configured, and the read-only repository scout by default; each can be
  turned off for a session;
- `--elixir` is an explicit profile whose only built-in tool is the Elixir
  evaluator.

This stays customizable without becoming a plugin pipeline inside the turn
loop. Tools implement one behaviour, hooks attach at named boundaries, and
hosts own the list.

The same rule covers every other default. Compaction, the stop-when-stuck
policy, the sentences the model reads on a denial, provider admission and a
tool's receipt on screen are each a behaviour with a shipped default, a theme
is data a host or a config file replaces, and `Lemieux.Harness` holds all of
their current settings. A `Lemieux.Extension` replaces a field or wraps one.
The `lmx` hosts are assembled from shipped extensions through the same
callback, and a person who dislikes one of them swaps it. A test over the
compiled modules keeps the loop from ever naming a host or the learning
toolchain. See [Extensions](extensions.md).

## Where Lemieux is intentionally not the same

### It does not invent subscription entitlement data

ReqLLM may be configured with API keys, OAuth credentials, or a provider's
supported subscription-compatible path. Lemieux passes provider policy through
that seam; it does not scrape a vendor CLI's private credential store or quota
screen. Missing USD pricing therefore means only "unmeasured", not
"subscription". Session and weekly allowance displays belong here once a
provider or host supplies stable remaining and reset data. Until then, token
usage is reported and quota percentages are not guessed.

### It is not an operating-system sandbox

Hooks can allow, deny, rewrite or asynchronously approve a tool call. The
environment can move file and command execution elsewhere. Neither means the
default local process is a security boundary. `lmx`'s opt-in `--sandbox` puts
the agent's commands in an operating-system sandbox and leaves MCP servers,
hooks, web tools and the Elixir evaluator outside it, as well as the git that
records changes for `/undo`, which runs nothing the repository configures.
See [Security](../SECURITY.md).

### It is not a web application or database

The core takes neither dependency. A host supplies its own store and may
expose sessions over Phoenix, SSH, Erlang distribution, A2A HTTP, or no
network at all.

### It does not start itself

Adding the dependency starts no Lemieux processes. Embedders mount
`Lemieux.Supervisor` and own its lifecycle, which also lets several isolated
Lemieux runtimes share one VM.

### Repository discovery has an explicit trust boundary

`AGENTS.md`, `CLAUDE.md` and skill prose are discovered as model context.
Native extensions, command hooks and plugins require explicit selection. A
repository's `.mcp.json` waits for a decision: its servers start only once you
have trusted that file (the terminal UI asks, and remembers the answer until
the file changes), because a stdio server runs a command the repository chose.
A repository's learned overlay, `.lmx/harness.json`, may only add
system-prompt text, and `lmx` names it at every start. Startup notices name
the selected files and servers. The library discovers none of these unless
its host opts in. The whole boundary is in the
[trust model](../SECURITY.md#what-lmx-trusts-by-default).

## Choosing whether Lemieux fits

Lemieux is a good fit when you need one or more of these:

- direct API access across providers, or local models;
- an embeddable Elixir runtime;
- owned, inspectable transcripts;
- steering and questions while a turn runs;
- approval, budget or environment policy controlled by the host;
- offline inspection, fork and replay;
- defaults you can replace, rather than a fixed product tool catalog.

It is a poor fit when your main goal is to use a vendor subscription, when you
need a turnkey operating-system sandbox, or when your policy requires binaries
signed by the operating-system vendor. `lmx` releases are signed with the
project's own Ed25519 key, which the installer and the updater check, but the
macOS and Windows builds are not signed by Apple or Microsoft. Those are real
product boundaries, not documentation footnotes.

## Which surfaces are library-only today

The runtime is broader than the stock CLI. `lmx` exposes ordinary sessions,
transcripts, models, MCP, command hooks, skills and plugins, the Elixir
profile, request and dollar limits (`--max-requests`, `--max-cost-usd`), web
search and page fetch (on when a Brave key is set), the read-only scout it
adds by default (`--no-delegate` removes it), Ixway routing behind `--ixway`
and `--router`, a personal `--config` file, and a repository's learned
overlay in `.lmx/harness.json`, which it names whenever it applies one. It
also exposes the experimental learning commands: feedback capture with
`--mine` and `draft-case`, `corpus promote`,
`harness verify|materialize|export`, the guided extension builder behind
`--build-ext`, and `--extension-profile`.

Embedding hosts additionally control:

- budget policy computed in host code, beyond fixed limits;
- asynchronous approval decisions made by the host;
- structured output schemas;
- custom tool lists and profile selection;
- replacement stores and tool environments;
- multiple subscribers and host-specific event delivery.

The experimental benchmark and discovery runtimes are reachable from a source
checkout through the `mix lemieux.*` tasks, not from `lmx`.

This split is intentional, but it should not be invisible: a feature in the
library is not automatically a flag in the CLI host.
