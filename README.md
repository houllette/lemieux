# Lemieux

[![CI](https://github.com/houllette/lemieux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/houllette/lemieux/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/lemieux.svg)](https://hex.pm/packages/lemieux)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/lemieux)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**An open-source coding agent you can take apart: a terminal app (lmx), and the Elixir runtime underneath it (Lemieux).**

**`lmx`** is a coding agent for your terminal: it reads your code, edits
files, runs commands and checks its work with your project's own tests, on
any model [ReqLLM](https://hex.pm/packages/req_llm) supports or a local one in
Ollama. **Lemieux** is the Elixir library underneath. It runs the agent loop
itself, with no vendor CLI behind it, and `lmx` is built on its public API.

![lmx's terminal interface exploring a project](docs/assets/lmx-preview.gif)

## Contents

- [What makes it different](#what-makes-it-different)
- [Also included](#also-included)
- [Install](#install)
- [Quickstart](#quickstart)
- [Safety](#safety)
- [When to use it](#when-to-use-it)
- [FAQ](#faq)
- [Documentation](#documentation)
- [Project status](#project-status)
- [Contributing and community](#contributing-and-community)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## What makes it different

The loop behind `lmx` is a library you can read, extend and embed, rather
than a program you drive from outside. That is where the differences come
from:

- **Every session is a transcript you can take apart.** A session is an
  append-only record on your disk. Resume it (`lmx -c`, or by name:
  `lmx --resume wayne-gretzky`), fork it from an earlier turn
  (`lmx fork SESSION --at-turn 2`), switch models halfway through (`/model`),
  or print the exact request `lmx` sent for any model call, with its system
  prompt, tool schemas and the transcript entries it carried
  (`lmx request`).
- **Its behaviour is code you can replace.** Tools, compaction, the
  stop-when-stuck rule, the sentences the model reads on a denial and the
  status line are Elixir behaviours with shipped defaults, not prompts you
  hope the model follows. `lmx extension new NAME` writes a one-file
  extension that `lmx` compiles when it loads it, and `lmx` itself is
  assembled from the same kind of extensions.
- **It runs on OTP.** A session is a supervised process, so it keeps
  listening while it works: type while the model is busy and your message
  reaches its next request (`/unsteer` takes it back). A tool that crashes
  becomes an error the model can read, not a dead session. An installed
  `lmx` is an OTP release, so a compatible, signed update can load into the
  terminal UI while it runs.
- **The same loop runs in your application.** Add `{:lemieux, "~> 0.8"}`,
  mount `Lemieux.Supervisor`, and supply your own tools, store, approval
  policy and interface through the API `lmx` uses; `lmx` has no private path
  into the library. [First embedded agent](docs/first-embedded-agent.md) runs
  a complete session without an API key.

## Also included

What you would expect from a coding agent is here too:

- **Any model.** Anthropic, OpenAI, Google Gemini, any other ReqLLM provider,
  or a local Ollama model that can call tools; `/model` and `/provider`
  switch at any time.
- **It checks its own work.** After a turn that edits files, `lmx` runs your
  project's check (`make test`, `mix test`, `npm test`, `cargo test`,
  `pytest` and others) and gives the model up to two more tries if it fails.
- **`/undo` and `/redo`**, covering what commands changed in a git
  repository as well as file edits
  ([what they cover](docs/everyday.md#taking-changes-back)).
- **Your Claude Code setup, within limits.** `CLAUDE.md` and `AGENTS.md`,
  Agent Skills, commands, subagents, plugins, hooks and MCP servers
  ([compatibility table](docs/configuration.md#compatibility-and-trust-boundary)).
- **Scripting.** `lmx run "…"` prints only the answer and exits with a status
  that says what happened; `--output-format json` or `stream-json` for tools
  and CI.
- **MCP servers, web search and fetch** (with a Brave key), and a
  [desktop launcher](docs/desktop.md) on Linux, Omarchy included.

## Install

### The `lmx` binary

On macOS and Linux, one command installs `lmx` for your user under
`~/.local` (no root needed):

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
```

The installer needs `curl` and Python 3.8 or newer. It checks the release's
signature and checksums before it installs anything, runs nothing from the
archive, and prints where it put `lmx`: add `~/.local/bin` to your `PATH` if
it is not there already. Options go after `sh -s --`: `--prefix DIR`,
`--release X.Y.Z`, and `--replace` to install over a `PREFIX/bin/lmx` the
installer did not write. To upgrade, run `lmx update`.

| Platform | Status |
| --- | --- |
| macOS, Apple Silicon or Intel | Supported on macOS 15 or later. The build is not signed by Apple: install it with the installer, not by unpacking the archive in Finder. |
| Linux x86-64 | Supported on glibc 2.34 or newer with its `libgcc_s` (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, Rocky, Alma, openSUSE, Amazon Linux 2023), with `ca-certificates` and `awk` installed (some slim container images leave them out). Not musl distributions such as Alpine. |
| Linux arm64 | No binary yet: run it from source. |
| Windows x86-64 | Experimental. Unpack `lmx_windows.tar.gz` from the [latest release](https://github.com/houllette/lemieux/releases/latest) into a new directory and run `bin\lmx.cmd` there ([the steps](docs/releases.md#windows-experimental)); update by downloading the new archive. Needs Git for Windows: its Git Bash runs the agent's commands, and WSL's bash is never used. Under WSL2, install the Linux build inside WSL instead. |

An installed `lmx` checks for new releases and installs one only after its
signature verifies against the key built into it; `lmx update` does the same
from a terminal. `LMX_AUTO_UPDATE=0` keeps the notices but installs only on
`lmx update` or `/update`, and `LMX_CHECK_UPDATES=0` turns the automatic
checks off. The first download trusts HTTPS
and GitHub; to check a release yourself, follow
[Verify a download](docs/releases.md#verify-a-download). The release-signing
public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`. On Linux,
`lmx desktop install` adds `lmx` to your application launcher
([Desktop launchers and Omarchy](docs/desktop.md)).

### From source

You need git and [mise](https://mise.jdx.dev/), which installs the Erlang and
Elixir versions the project pins:

```sh
git clone https://github.com/houllette/lemieux.git
cd lemieux
mise install
mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout. The first
run compiles everything, in about a minute, with dependency warnings you can
ignore. On Linux distributions other than
Ubuntu, `mise install` builds Erlang and needs a few packages first;
[First session](docs/getting-started.md#from-a-source-checkout) lists them and
shows how to make `lmx` work from any directory.

### As a library

```elixir
def deps do
  [{:lemieux, "~> 0.8"}]
end
```

Lemieux needs Elixir 1.19 or newer on Erlang/OTP 27 or newer. Adding it starts
no Lemieux processes: mount `{Lemieux.Supervisor, name: MyApp.Agents}` in your
supervision tree. ReqLLM, which makes the model calls, loads the `.env` file
in the directory your application starts in and runs any `$(...)` in it; if
that directory may be untrusted, set `config :req_llm, load_dotenv: false`
([For library hosts](SECURITY.md#for-library-hosts)).

## Quickstart

1. **Give `lmx` a model.** Export one provider's key:

   ```sh
   export ANTHROPIC_API_KEY=...   # or OPENAI_API_KEY, GOOGLE_API_KEY, ... (lmx help models)
   ```

   Or run a model that can call tools in [Ollama](https://ollama.com), started
   with a long enough context window: `OLLAMA_CONTEXT_LENGTH=65536 ollama serve`
   (32768 at the least; with less than about 23 GiB of GPU memory, Ollama
   otherwise serves 4,096 tokens and silently drops the start of a longer
   conversation, your task first). With neither, `lmx` opens a panel where you
   pick a provider and paste its key.
2. **Start it in your project:**

   ```sh
   cd /path/to/your/project
   lmx
   ```

3. **Ask something:** `Explain how this project is organized, then suggest
   one small improvement. Do not change files yet.`

`/help` lists commands and keys, `/undo` takes back the last turn, and `/quit`
leaves; `lmx -c` picks up where you left off. Settings live in
`~/.lmx/config.json` (only you can read it) and transcripts in
`~/.lmx/sessions`. Your provider bills API requests; see
[What does it cost?](#what-does-it-cost) for the caps.
[First session](docs/getting-started.md) walks through all of this, and
[Everyday use](docs/everyday.md) covers the rest.

## Safety

`lmx` starts in **full auto**, and its startup banner says so: it runs every
tool call without asking, and its commands run as your user, without a
sandbox, in the environment you started it in, less variables whose names
contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` (by name only: a
password inside `DATABASE_URL` still passes). After a turn that edits files
it also runs the check command the repository chose, unasked;
`"verify": false` in `~/.lmx/config.json` turns that off.

- **Ask first:** `lmx --permission-mode ask` asks before edits and commands;
  `--permission-mode accept_edits` asks only before commands.
- **Confine commands:** `lmx --sandbox` runs them inside macOS Seatbelt or
  Linux bubblewrap (install `bubblewrap` first). They can write only to the
  project, temporary directories and tool caches, reach no network beyond
  loopback, and cannot see credential locations such as `~/.ssh`, `~/.aws`
  and `~/.lmx` (`lmx help sandbox` lists them all). The sandbox does not
  cover MCP servers, hooks, web tools or the Elixir evaluator, and a
  sandboxed command can still change the repository's `.git/config` and
  hooks, which the `git` you run afterwards will use.
- **Guarded by default:** file tools stay inside the working directory,
  `write` will not replace a file the session has not read, a repository's
  `.mcp.json` servers wait until you trust that file, a repository's hooks
  never run on their own, and the installed `lmx` never reads a `.env` file
  from the directory it starts in.
- **What leaves your machine:** your conversation and the instruction files
  `lmx` reads (the repository's and your own, such as `~/.claude/CLAUDE.md`),
  to the model provider or gateway you chose; calls to the MCP servers you
  connect; update checks, to GitHub; web searches and fetched pages once you
  set a Brave key; and whatever the agent's commands send, since without
  `--sandbox` they have your network access. The bundled
  [System One compaction](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md)
  extension sends abridged conversation text only once you configure a
  provider: a TypeSafe key (`JEV_API_KEY`), an Ixway gateway, or another
  System One service, which can be an open model on your own machine.

The [trust model](SECURITY.md#what-lmx-trusts-by-default) lists exactly what is
guarded and what is not.

## When to use it

Claude Code, Codex CLI, OpenCode and Aider are capable, widely used terminal
agents; if one of them fits how you work, use it. `lmx` is for when you want
to own the harness: to see and fork exactly what a session did, to change how
the agent behaves in code rather than in prompts, or to run the same loop
inside your own Elixir application. It is Apache-2.0 licensed and works with
any model ReqLLM supports.

## FAQ

### Do I need to know Elixir to use lmx?

No. The binary bundles its own Erlang runtime, and the source route installs
Erlang and Elixir for you. Everything you configure is plain text: JSON
settings, Markdown instructions and skills, shell-command hooks and MCP
servers. You need Elixir only to write an extension or to embed the library.

### Why Elixir?

An agent is mostly concurrency and state, which is what OTP is for. Each
session is a supervised process with a single ordered transcript writer, and
model calls, tools, hooks and compaction run as supervised work beside it, so
the session keeps taking your steering, cancellation and approvals while a
command runs. Events are ordinary messages, which a Phoenix app can stream to
a page. [Why Lemieux](docs/why-lemieux.md) has the longer version.

### Which models work best?

`lmx` needs a model that can call tools. It is developed mainly against
Anthropic's models. Anthropic, OpenAI, Google Gemini, Z.AI Coding Plan and a
local Ollama model each have an opt-in live test that runs a whole session,
tool calls included; the [validation matrix](docs/providers.md#validation-matrix)
has the details. Other ReqLLM providers go through the same code but have no
live test. A local model needs Ollama to serve it with a context window of at
least 32k tokens. `lmx help models` lists the model `lmx` starts on for each
provider's key.

### What does it cost?

Lemieux is free and Apache-2.0 licensed. You pay your model provider for API
use, or nothing for a local model. The status line shows tokens and, when the
model's price is known, cost. `--max-cost-usd 2` stops a session before a
request that could take it past $2 (and outright when the price is unknown),
and `--max-requests 20` caps its requests. The read-only repository scout, on
by default, spends from its own cap of $9 per session; `--no-delegate` turns
it off when one number must bound everything.

### Why "Lemieux"?

It is named in memory of Claude Lemieux, four-time Stanley Cup champion, who
began his career with the Montreal Canadiens. The name is also a wink: Claude
Code is an agent harness, and so is this one. Hockey runs through the project.
Every session gets the name of a real professional hockey player (from the
NHL, the PWHL, and five from the CWHL), derived from its id, so you can type
`lmx --resume marie-philip-poulin` instead of a 26-character id. A GO HABS GO
banner plays while `lmx` starts. The names come from public NHL and PWHL
roster listings and Hockey Hall of Fame player pages, and names that read as
crude out of context are never generated. Lemieux is not affiliated with or
endorsed by the NHL, the PWHL or the Hockey Hall of Fame.

## Documentation

| Start here | Then |
| --- | --- |
| [First session with lmx](docs/getting-started.md) | [Everyday use](docs/everyday.md) · [CLI reference](docs/cli.md) · [Configuration](docs/configuration.md) · [Troubleshooting](docs/troubleshooting.md) |
| [First embedded agent](docs/first-embedded-agent.md) | [Embedding Lemieux](docs/embedding.md) · [Hooks and policy](docs/hooks.md) · [Telemetry](docs/telemetry.md) |
| [Your first extension](docs/first-extension.md) | [Customizing Lemieux](docs/customization.md) · [Extensions](docs/extensions.md) · [Examples](https://github.com/houllette/lemieux/blob/main/examples/README.md) |
| [Why Lemieux](docs/why-lemieux.md) | [Transcripts](docs/transcript-compatibility.md) · [Support and compatibility](docs/support.md) |

The [examples](https://github.com/houllette/lemieux/blob/main/examples/README.md)
are runnable agents and extensions, each with a check that runs offline. All
guides and the API reference are on [HexDocs](https://hexdocs.pm/lemieux).

## Project status

Lemieux 0.8 is the first public release, with one maintainer. The contracts that
[Support and compatibility](docs/support.md) lists as supported (sessions,
tools, transcripts, resume and fork, extensions) have offline tests, and
`lmx` is the supported first-party host. APIs may still change before 1.0,
with migration notes in the [changelog](CHANGELOG.md).

Experimental, and free to change in any 0.x release: the harness-learning,
feedback, benchmarking and evaluation tools (modules whose documentation opens
with **Experimental.**, `lmx feedback`, `lmx corpus` and `lmx harness`, and
the `mix lemieux.*` tasks), the Windows build, and the computer-use example.
The [roadmap](docs/roadmap.md) lists what comes next.

## Contributing and community

- **Questions and ideas:** [GitHub Discussions](https://github.com/houllette/lemieux/discussions).
- **Bugs:** [open an issue](https://github.com/houllette/lemieux/issues/new/choose).
  Never paste API keys, `.env` files, transcripts or crash dumps.
- **Code and docs:** [CONTRIBUTING.md](CONTRIBUTING.md) maps the source tree
  and the checks to run (`mix precommit`). The ordinary test suite needs no
  API key. Before a larger change, such as a new dependency, a provider
  adapter, or a change to the transcript format, the extension and hook
  contracts or supervision, start a conversation in
  [Discussions → Ideas](https://github.com/houllette/lemieux/discussions/categories/ideas).
- **Security:** report vulnerabilities privately, as [SECURITY.md](SECURITY.md)
  describes.
- **Conduct:** the [Code of Conduct](https://github.com/houllette/lemieux/blob/main/CODE_OF_CONDUCT.md)
  applies everywhere the project meets.

## License

Lemieux is licensed under the [Apache License 2.0](LICENSE). Attributions are in
[NOTICE](https://github.com/houllette/lemieux/blob/main/NOTICE). Every `lmx`
release archive also carries `THIRD_PARTY_NOTICES`, covering the Erlang/OTP
runtime and the libraries it bundles. Contributions are accepted under the
same license.

## Acknowledgements

[Pi](https://github.com/earendil-works/pi) and its Python port
[tau](https://github.com/huggingface/tau) inspired the native loop and the four
default tools. [Codex](https://github.com/openai/codex),
[Claude Code](https://github.com/anthropics/claude-code) and
[Gemini CLI](https://github.com/google-gemini/gemini-cli) informed the
interactive experience, workspace conventions and hooks. The `apply_patch`
tool follows Codex's patch format and matching (`codex-rs/apply-patch`,
Apache-2.0). [ReqLLM](https://hex.pm/packages/req_llm) provides model
integration, and [ExRatatui](https://hex.pm/packages/ex_ratatui) powers the
terminal UI.

Thanks also to [Alloy](https://github.com/alloy-ex/alloy),
[Ash AI](https://github.com/ash-project/ash_ai),
[Whisperer](https://github.com/Monitor-Lizzard/whisperer),
[Sagents](https://github.com/sagents-ai/sagents),
[Legion](https://github.com/software-mansion/legion),
[LangChain](https://github.com/brainlid/langchain),
[Jido](https://github.com/agentjido/jido),
[beamcore](https://github.com/beamcore/agent) and
[ex_athena](https://github.com/udin-io/ex_athena), whose published designs
informed Lemieux's tool, feedback, telemetry, evaluation and terminal
boundaries; [Why Lemieux](docs/why-lemieux.md#what-came-from-other-harnesses)
describes those influences. The bundled System One compaction extension adapts the
selective idea in [fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction),
and the experimental computer-use example adapts portions of
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast) (MIT).
