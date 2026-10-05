# lmx release host

This Mix project builds the native `lmx` binary: an OTP release that bundles
the Erlang runtime, Elixir, the Lemieux library (`../..`), the terminal UI's
native library and the [Jev compaction extension](extensions/jev_compaction/README.md).
It is the only place that starts anything: it owns the application callback
(`Lmx.Application`), the launcher and self-updates, so the `:lemieux` library
can keep starting nothing when a host embeds it.

You need this directory to build, test or change the binary. To run `lmx`
from source, use the repository root: `mise exec -- mix lmx ARGS` runs any
command, and bare `mise exec -- mix lmx` opens the terminal UI. A source run
from here also has the bundled Jev extension. This project has its own
dependencies, so fetch them first:

```sh
cd dist/lmx
mise exec -- mix deps.get
mise exec -- mix lmx -C ../..    # the terminal UI, working on the checkout
```

Unlike a run from the repository root, this one reads no `.env`
(`config/config.exs` turns that off, as in the binary): put your provider's
key, and `JEV_API_KEY` for Jev, in your environment or in
`~/.lmx/config.json`.

## Layout

| Path | What it is |
| --- | --- |
| `lib/lmx/release.ex` | Release assembly: launchers, distribution and cookie defaults, pruning, the archive check. Its moduledoc says what is changed from Mix's and Forecastle's output, and why. |
| `lib/lmx/notices.ex` | Writes `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES` into every archive. |
| `lib/lmx/boot.ex` | Runs a command in the release VM; Ctrl-C, a closed terminal, SIGTERM and a killed launcher cancel the running turn. |
| `lib/lmx/update.ex` | Installed-binary updates. |
| `priv/launcher.sh`, `priv/launcher.ps1` | `bin/lmx` on Unix; `bin/lmx.ps1` (run by `bin/lmx.cmd`) on Windows. |
| `rel/vm.args.eex` | VM flags: UTF-8 file names, no BREAK menu, a bounded shutdown. |
| `config/config.exs` | Release configuration: the binary never reads a working directory's `.env`. |
| `extensions/jev_compaction` | The bundled Jev extension, its own Mix project. |
| `notices/` | Reviewed inputs for `THIRD_PARTY_NOTICES` (see below). |
| `upgrades/` | One reviewed upgrade decision per version; see [upgrades/README.md](upgrades/README.md). |

## Build one target

Build on the platform you target; the build refuses a mismatched host.

| `LMX_TARGET` | Platform |
| --- | --- |
| `macos_silicon` | macOS on Apple silicon (unsigned) |
| `macos` | macOS on Intel (unsigned) |
| `linux` | Linux x86-64 (release builds use the static-OpenSSL Erlang/OTP from `scripts/build-static-otp.sh`) |
| `windows` | Windows x86-64, experimental: needs Git Bash; under WSL2 use the Linux build |

Linux arm64 has no binary yet; use a source checkout there.

```sh
cd dist/lmx
mise exec -- mix deps.get
LMX_TARGET=macos_silicon MIX_ENV=prod mise exec -- mix release --overwrite
_build/prod/rel/lmx/bin/lmx --version
```

The release is in `_build/prod/rel/lmx` and the archive in
`_build/prod/lmx-VERSION.tar.gz`, with `LICENSE`, `NOTICE` and
`THIRD_PARTY_NOTICES` at its root. The build fails if the archive lacks them,
ships a cookie, or carries another platform's process helper or Erlang's
development tools (`erlc`, `escript`, `dialyzer` and the like).

To install a local build the way a download is installed (per user; the
installer refuses system-wide installs), name the archive for its target and
write a checksum file:

```sh
cp _build/prod/lmx-0.8.0.tar.gz /tmp/lmx_macos_silicon.tar.gz
(cd /tmp && shasum -a 256 lmx_macos_silicon.tar.gz > SHA256SUMS)
python3 ../../scripts/install.py /tmp/lmx_macos_silicon.tar.gz --checksums /tmp/SHA256SUMS
```

A local archive has no release signature; the installer says so and installs
it on the strength of the checksum you wrote.

## How the binary behaves

These differ from a stock Mix release on purpose; `Lmx.Release`, `Lmx.Boot`
and `priv/launcher.sh` say why next to the code.

- It never reads a working directory's `.env` (`config/config.exs`).
- Ctrl-C, a closed terminal and SIGTERM cancel the running turn before the
  VM stops. The launcher then exits 130, 129 or 143. A killed launcher's VM
  notices within about a second and stops the same way: the terminal UI
  leaves its screen, the VM says why on standard error, and it exits 143.
- Crash dumps go to `$LMX_HOME/crash` (by default `~/.lmx/crash`, mode
  0700) unless `ERL_CRASH_DUMP` is already set.
- The commands the agent runs, hooks, MCP stdio servers and the editor get
  the environment the person started `lmx` with, not the VM's: the launcher
  records `PATH` and the variables it, `erlexec` and the release script are
  about to set (`LMX_PARENT_PATH`, `LMX_PARENT__NAME`), and
  `Lmx.CLI.inherited/1` turns those records into what
  `Lemieux.Environment.Inherited` applies. Without it, a person's own `erl`,
  `elixir` and `mix` resolved to the release's runtime and stopped with
  `cannot get bootfile`.
- The Unix launcher puts `+fnu` in `ELIXIR_ERL_OPTIONS`, so every VM the
  release script starts reads file names as UTF-8 whatever the locale,
  Castle's short-lived first-start VM included (`rel/vm.args.eex` covers
  only the VM a command runs in). The agent's commands get the person's own
  `ELIXIR_ERL_OPTIONS` back.
- `bin/lmx-release`, the underlying Mix release script, starts without
  distribution, and no cookie ships. `RELEASE_DISTRIBUTION=sname` (or
  `name`) opts in and, without `RELEASE_COOKIE`, creates a cookie for that
  installation, readable by its owner only, the first time.
- No heart process runs.

## Test it

```sh
mise exec -- mix test --warnings-as-errors
```

The Python smoke tests drive a built binary without calling any model. Give
them the release's launcher, or an installed one:

```sh
python3 ../../test/release_extension_smoke.py _build/prod/rel/lmx/bin/lmx
python3 ../../test/release_session_smoke.py _build/prod/rel/lmx/bin/lmx
python3 ../../test/release_stdin_smoke.py _build/prod/rel/lmx/bin/lmx
# Builds three releases in a temporary copy and upgrades between them; slow.
LMX_MIX='mise exec -- mix' python3 ../../test/release_upgrade_smoke.py
```

`release_session_smoke.py` also checks the notices, that `--version` and
`help` write nothing to standard error, that a working directory's `.env` is
ignored, that a command the agent runs gets the person's `PATH` and none of
the release's variables (and that their own `erl` runs, when their `PATH`
has one), that Ctrl-C, a closed terminal, SIGTERM (to the launcher or to the
VM itself) and a killed launcher cancel a running turn and run the VM's
SIGTERM traps, and, on a pseudo-terminal, that the terminal UI leaves its
screen when its launcher is killed (the VM saying why only after that) or its
VM is sent SIGTERM, which must then exit 143.

`mix precommit` at the repository root runs this project's dependency audit,
compile, format and tests; `mix deps.drift` checks that this lockfile resolves
shared dependencies the way the library's does.

## Third-party notices

`THIRD_PARTY_NOTICES` is assembled at build time from what the build bundles.
What the build cannot read from its inputs is committed under `notices/` and
reviewed:

- `crates.txt`: the Rust crates in the terminal library's native code.
  Regenerate it when ex_ratatui changes (the build and the tests refuse a
  different version or Cargo.lock), then review the diff:
  `mise exec -- elixir notices/generate_crates.exs` (needs cargo and network).
- `runtime/`: license texts of code inside Erlang/OTP's runtime and of the Go
  runtime in ExCmd's helper. `Lmx.Notices` records the Erlang/OTP version they
  were reviewed for; a different one stops the build.
- `hex/`: upstream license files for Hex packages that ship none.
- `licenses/`: one canonical text per SPDX license identifier used.

## Releasing

Read [Installing and updating lmx](../../docs/releases.md) and
[RELEASING.md](../../RELEASING.md) before tagging. Every version needs a
reviewed `upgrades/VERSION.exs`.

Releases are signed with an offline Ed25519 key, and this project holds the
maintainer's tasks for it. Only the maintainer runs the first three of them;
agents and CI never do:

| Task | What it does |
| --- | --- |
| `mix lmx.release.keygen` | Generates the key once (`--rotate` replaces a pinned one), and pins its public half in `release-signing.pub` and `scripts/install.py` |
| `mix lmx.release.sign` | Signs files by hand, as a key rotation needs |
| `mix lmx.release.sign_draft` | Checks a draft GitHub release, then signs and uploads its `SHA256SUMS` and `update.json` |
| `mix lmx.release.verify` | Verifies signed files; needs no private key |

Until the maintainer generates the key, `release-signing.pub` and
`RELEASE_PUBLIC_KEY` in `scripts/install.py` read `UNSET`. A build made then
installs no update, `install.py` installs only a local archive with
`--checksums`, `mix lmx.release.verify` needs `--public-key`, and a tag build
of the release workflow stops at its first step. RELEASING.md describes the
whole ceremony.
