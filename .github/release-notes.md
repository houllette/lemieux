# Lemieux 0.8.1

The first update to the public release: four fixes from the first week of
reports, and a way to update from a terminal.

## What changed

- **`lmx update`** installs a newer release from a terminal, after the same
  signature, checksum and archive checks as the terminal UI's `/update`;
  `lmx update --check` only says whether one is available. It needs no
  session, model key or readable config file, so it works while a mistake in
  `~/.lmx/config.json` keeps the screen from opening. Rerunning the installer
  now upgrades its own installation without `--replace`, which is only for
  installing over a `PREFIX/bin/lmx` the installer did not write. (#5)
- **A config file with empty key placeholders loads.** `"api_key": ""` under
  `providers`, `ixway`, `jev_compaction` or `web_search_providers` counts as
  no key, is named in the startup notices, and no longer stops every command
  with `Invalid lmx config field: web_search_providers.` A value a field
  cannot take names the field down to its key and what it takes.
  `"web_search": "brave"` saved without a Brave key is a startup warning and
  no search rather than a refused start. (#3)
- **Skills from other harnesses have their own tabs** in the slash menu. A
  bare `/` lists `lmx`'s own commands; skills from the repository, your
  `~/.lmx/skills`, Claude Code's or Codex's directories, Omarchy, plugins or
  a `--skill-dir` sit on tabs named for where they came from, switched with
  Shift-Tab or a click. Typing a skill's name jumps to its tab. (#1)
- **The Go Habs Go banner plays out** once the session is ready rather than
  vanishing with it, so a fast start still shows it; any key ends it. When
  `NO_COLOR` is set in the environment `lmx` started in — a desktop launcher
  or a coding agent's shell often sets it — a startup notice names the
  variable and where to unset it, `/theme` shows `(NO_COLOR is set)`, and
  `lmx explain` reports `TERM`, `COLORTERM` and `NO_COLOR` under
  `diagnostics.terminal`. (#4)

The [changelog](https://github.com/houllette/lemieux/blob/v0.8.1/CHANGELOG.md)
has the details.

## Updating from 0.8.0

An `lmx` installed with `install.sh` or `install.py` installs this release on
its own once its signed manifest is published, or now:

```sh
lmx update
```

This is a restart release on every platform: 0.8.1 adds a module that 0.8.0
does not have, so no running screen takes it live. Installed copies stage it
and say to restart; save an unsent draft, quit, and start `lmx -c` to resume
where you were. `LMX_AUTO_UPDATE=0` keeps the notices and installs only on
`lmx update` or `/update`. The Windows build is updated by downloading the new
archive.

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
[Verify a download](https://github.com/houllette/lemieux/blob/v0.8.1/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, and
`mix lmx update` fast-forwards it from its Git upstream.

**As a library**, add `{:lemieux, "~> 0.8"}` to your dependencies and start
with [First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key. No library API changed in
this release.

## Before your first session

- `lmx` runs tools **without asking** by default, and `bash` runs as your
  user, not sandboxed; the startup notice says "full auto". Use
  `--permission-mode ask` to approve each action and `--sandbox` to confine
  commands.
  [What lmx trusts by default](https://github.com/houllette/lemieux/blob/v0.8.1/SECURITY.md#what-lmx-trusts-by-default)
  has the whole trust model.
- Your provider bills the requests `lmx` makes; `--max-requests` and
  `--max-cost-usd` set limits. With no key set, `lmx` uses a local Ollama
  model that can call tools if Ollama serves one; otherwise the terminal UI
  asks you to choose a provider.
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
