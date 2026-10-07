# Lemieux 0.9.1

0.9.1 is 0.9.0, signed. 0.9.0 was published without the signatures that
`install.sh` and every installed `lmx` check, so neither would install it;
0.9.1 is the same code with them. Everything below is what changed since
0.8.1.

Long tasks keep going, extensions can bring their own model routes, and Jev
compaction becomes System One compaction, which any System One provider in
your config can serve. One config change stops a start until you make it;
read [Before you restart](#before-you-restart) first if your
`~/.lmx/config.json` mentions `jev_compaction`.

## Before you restart

0.9.1 refuses to start while `~/.lmx/config.json` has a `"jev_compaction"` or
`"jev_compaction_providers"` key, or `"disabled_extensions":
["jev_compaction"]`. It stops with a sentence naming the new keys rather than
ignoring the old ones, since ignoring them would quietly switch compaction
off. Move them before you restart into 0.9.1:

| Was | Now |
| --- | --- |
| `jev_compaction.mode`, `.max_evaluations`, `.max_cost_usd`, `.reservation_per_call_usd` | the same fields under `systemone_compaction` |
| `jev_compaction.route` or `.provider` | `systemone_compaction.provider` |
| `jev_compaction.api_key` | `systemone_providers.typesafe.api_key` |
| `jev_compaction.endpoint` | `systemone_providers.ixway.base_url` |
| `jev_compaction.model` | `model` in the selected provider's entry |
| `jev_compaction_providers.NAME` | `systemone_providers.NAME` |
| `"disabled_extensions": ["jev_compaction"]` | `"disabled_extensions": ["systemone_compaction"]` |

`JEV_API_KEY` is unchanged.
[Moving from Jev compaction](https://github.com/houllette/lemieux/blob/v0.9.1/docs/compaction.md#moving-from-jev-compaction)
has the whole table and what happens to a session recorded before the rename.
A config without those keys needs no change.

A script extension whose manifest names a bare version, such as
`"versions": {"lemieux": "0.8.0"}`, was written for the 0.8 line and is not
loaded by 0.9.1; update the script and give it `"~> 0.9"` or `"0.9.0"`.
Extensions built with `mix lmx.extension.build` keep loading.

## What changed

- **A long task keeps going.** When the model ends its turn while the plan it
  wrote with `todo` still has open tasks, `lmx` sends it back to them with a
  list of what is left, at most five times a prompt; an answer that calls no
  tool is taken as its decision to stop. An answer cut off at the
  output-token limit is picked up again, at most three times, and a tool call
  the limit cut short is no longer run with empty arguments: the model is
  told to write the file in smaller parts. Messages `lmx` sends the model are
  drawn as `lmx` speaking (`↻`, or `✓` for the check after edits).
  `"continuation"` sets the allowances, and `"continuation": false` turns it
  off ([Continuing unfinished work](https://github.com/houllette/lemieux/blob/v0.9.1/docs/configuration.md#continuing-unfinished-work)).
  (#21)
- **Extensions can register model routes.** An extension `lmx` loads can
  offer named routes beside Ixway; `--router NAME` and `LMX_ROUTER` select
  one, `/provider` and `/model` list its models, and `lmx explain` reports it.
  [Adding a model route](https://github.com/houllette/lemieux/blob/v0.9.1/docs/extensions.md#adding-a-model-route)
  is the guide, and `examples/extensions/relay` is a one-file route to an
  OpenAI-compatible server. (#14)
- **System One compaction reaches any System One provider.**
  `"systemone_providers"` declares each provider once (TypeSafe, Ixway, or
  any service that speaks `POST /v1/systemone`, including an open model on
  your own machine), and `"systemone_compaction"` chooses one. Nothing is
  sent to a provider that is not selected, and there is no fallback from one
  to another. The computer-use and research examples ask the same providers.
  (#6)
- **Cost caps work on the newest models.** On 0.8.1, a session with
  `--max-cost-usd` on 34 of the catalog's priced models, among them current
  Anthropic, OpenAI, Google, xAI and DeepSeek models, stopped before its
  first request with `its cost cannot be estimated`. Estimates now fall back
  to the model's list rates and say so. (#17)
- **Provider failures are classified better.** An HTTP `408` is a timeout,
  and a stream that ended before its first token is a server failure that
  the session retries, instead of both being recorded as the model failing.
  `lmx run` exits 6 (provider) for the second. (#15, #16)

The [changelog](https://github.com/houllette/lemieux/blob/v0.9.1/CHANGELOG.md)
has the details.

## Updating from 0.8.1

An `lmx` installed with `install.sh` or `install.py` installs this release on
its own once its signed manifest is published, or now:

```sh
lmx update
```

This is a restart release on every platform: 0.9.1 runs a newer Erlang/OTP
(29.1.1) and Elixir (1.20.4), and adds and removes modules, so no running
screen takes it live. Installed copies stage it and say to restart; move any
`jev_compaction` settings first ([Before you restart](#before-you-restart)),
save an unsent draft, quit, and start `lmx -c` to resume where you were.
`LMX_AUTO_UPDATE=0` keeps the notices and installs only on `lmx update` or
`/update`. The Windows build is updated by downloading the new archive.

An `lmx` 0.8.1 that reported 0.9.0 as "not signed yet" takes 0.9.1 the same
way, and so does a 0.9.0 installed by hand.

## Install lmx

On macOS and Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
lmx --version
```

The installer needs `curl` and Python 3.8 or newer. It checks the signature
on `SHA256SUMS` against the release key pinned in it, checks every download
against those checksums, installs for your user only (under `~/.local`), and
runs nothing from the archive while it installs.

| Platform | Archive | Notes |
| --- | --- | --- |
| macOS, Apple Silicon | `lmx_macos_silicon.tar.gz` | macOS 15 or later. Not signed by Apple: install it with `install.sh`, not by unpacking it in Finder. |
| macOS, Intel | `lmx_macos.tar.gz` | As above |
| Linux x86-64 | `lmx_linux.tar.gz` | glibc 2.34 or newer (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, openSUSE, Amazon Linux 2023), CA certificates and `awk` |
| Windows x86-64 | `lmx_windows.tar.gz` | Experimental: verify it, unpack it and run `bin\lmx.cmd`. Needs Git Bash, which Git for Windows installs; under WSL2, install the Linux build inside WSL |

Linux arm64 and musl distributions such as Alpine have no build yet; use the
source checkout. To check this release yourself before you run anything,
follow
[Verify a download](https://github.com/houllette/lemieux/blob/v0.9.1/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, and
`mix lmx update` fast-forwards it from its Git upstream.

**As a library**, add `{:lemieux, "~> 0.9"}` to your dependencies and start
with [First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key. Two library changes need a
host's attention:

- A stop hook's feedback is now a `:user` transcript entry with an extra
  `"stop_hook" => true` key. A host that compares that payload exactly
  should match on `"text"`, and use `Lemieux.Transcript.stop_hook?/1` to tell
  the hook's words from the person's.
- `Lemieux.CLI.ProviderMux.new/3` takes a list of `{name, provider}` routes
  in place of one Ixway provider; a host that built one passes
  `[{"ixway", ixway}]`.

The bundled compaction extension is now `LemieuxSystemOneCompaction`; its old
options are refused with a sentence saying where each value now goes. The
[changelog](https://github.com/houllette/lemieux/blob/v0.9.1/CHANGELOG.md)
lists every library change.

## Before your first session

- `lmx` runs tools **without asking** by default, and `bash` runs as your
  user, not sandboxed; the startup notice says "full auto". Use
  `--permission-mode ask` to approve each action and `--sandbox` to confine
  commands.
  [What lmx trusts by default](https://github.com/houllette/lemieux/blob/v0.9.1/SECURITY.md#what-lmx-trusts-by-default)
  has the whole trust model.
- Your provider bills the requests `lmx` makes; `--max-requests` and
  `--max-cost-usd` set limits. A task with open items in its plan sends the
  model back to them, which is more requests; `"continuation": false` turns
  that off. With no key set, `lmx` uses a local Ollama model that can call
  tools if Ollama serves one; otherwise the terminal UI asks you to choose a
  provider.
- Your personal instruction files (`~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md` and others) and skills go to the model together with
  the repository's; the slash menu keeps the skills on tabs named for where
  they came from.
- The installed `lmx` never reads a `.env` from the directory it starts in;
  keep keys in your environment or in `~/.lmx/config.json`.
- A repository's `.mcp.json` servers start only after you trust them.
- The installed `lmx` checks for updates hourly and installs one only after
  its signature verifies; `lmx update` does the same from a terminal.
  `LMX_CHECK_UPDATES=0` turns the automatic checks off.

## Known limitations

- Pre-1.0: a minor release may change library APIs, and the changelog says
  how to migrate.
- The macOS and Windows archives are not signed by Apple or Microsoft.
- Windows is experimental: no installer and no automatic updates.
- No Linux arm64 or musl build yet.
- `/undo` cannot put back everything a command changed (ignored files, files
  stored through Git LFS or another git filter, work outside a git
  repository, commits); it names what it could not.
- Harness learning, benchmarking and feedback workflows are experimental.

## Assets

The four archives, `install.sh` and `install.py`, `SHA256SUMS` and its
signature `SHA256SUMS.sig`, `update.json` (what installed copies read) and
`update.json.sig`, `LICENSE`, `NOTICE`, these notes and the upgrade plan.
`SHA256SUMS` lists every asset except the signatures.
