# Support, compatibility and upgrades

Lemieux is pre-1.0. This page says which parts are supported and which are
experimental, which platforms `lmx` runs on, and how to upgrade the library,
the binary and your extensions. The license is
[Apache 2.0](https://github.com/houllette/lemieux/blob/main/LICENSE).

Ask questions in [GitHub Discussions](https://github.com/houllette/lemieux/discussions),
report bugs as [issues](https://github.com/houllette/lemieux/issues), and
report vulnerabilities privately as [SECURITY.md](../SECURITY.md) describes.
Help is best effort; a small reproduction and the output of `lmx explain`
(reviewed before you share it) get the quickest answer. Never attach a crash
dump, a transcript or a log to a public issue: they can hold keys and source.

## What is supported

*Supported* means a documented contract, covered by tests that run without a
network, which changes only with a changelog entry. *Experimental* means it
may change in any 0.x release.

| Surface | Status |
| --- | --- |
| `lmx`: terminal UI, `lmx run`, sessions, resume and fork | Supported |
| Sessions, tools, transcripts, resume and fork in the library | Supported public contracts |
| `Lemieux.Harness`, `Lemieux.Extension` and the shipped extensions | Supported composition API; extensions are trusted code, and host policy wins |
| Model providers through ReqLLM | Supported integration; which models your account can use is up to the provider (see [providers](providers.md)) |
| MCP client and OAuth sign-in | Supported; each server's consent and refresh behaviour is its own |
| Claude Code skills, commands, plugins, hooks and `.mcp.json` | A documented subset; see [Claude Code compatibility](#claude-code-compatibility) |
| A2A 1.0 peers and the read-only A2A service | Implemented for peers you configure; see [A2A](a2a.md) |
| The `todo` plan, verification after edits, host-verified completion, delegation to the read-only scout | Supported optional features; how well they work depends on the task and the model |
| System One compaction | Bundled with `lmx`, which turns it on only when you configure a System One provider: a TypeSafe key, an Ixway gateway or one you declare ([trust model](../SECURITY.md#what-lmx-sends-and-where)); the library does not depend on it |
| Ixway gateway routing and hosted learning | Optional integration; not needed to use Lemieux (see [Ixway](ixway.md)) |
| Harness learning, tuning, confirmation, benchmarking, feedback and checkpointed agent composition | Experimental |
| The browser-automation example (`computer_use`) | Experimental, with its own prerequisites |

Every documented module in the experimental namespaces (`Lemieux.Learning`,
`Lemieux.Benchmark`, `Lemieux.Experiment`, `Lemieux.Asset`,
`Lemieux.Feedback`, `Lemieux.Reflection`, `Lemieux.Evidence`,
`Lemieux.Agent` and `Lemieux.Contract`) opens its documentation with
"**Experimental.** May change in any 0.x release.", and so does every
`mix lemieux.*` task. That includes `Lemieux.Learning.Overlay`, whose Elixir
API is experimental although `lmx` uses it to apply a learned overlay
(`.lmx/harness.json`), and `Lemieux.Contract`, whose digests supported
modules such as `Lemieux.Extension.Profile` use internally.

### Claude Code compatibility

`lmx` reads much of what a Claude Code setup contains, but not all of it.

What works:

- instruction files: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`,
  `AGENTS.override.md`, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, with
  `@path` imports confined as the
  [trust model](../SECURITY.md#guarded-by-default) describes;
- Agent Skills from `.agents/skills`, `.claude/skills`, `~/.lmx/skills` and
  `~/.claude/skills`; legacy slash commands from `.claude/commands`;
- subagent definitions (`.claude/agents`), used as read-only delegation
  targets;
- plugins from a local directory or a Git URL, and from marketplaces given as
  a local directory, a GitHub `OWNER/REPO`, a Git URL or a `marketplace.json`
  URL, with plugin sources that are relative, `github`, `url` or `git-subdir`;
  a selected plugin's skills, commands, agents, hooks and MCP servers;
- hooks in Claude Code's settings format, through `--hooks` or a plugin, for
  `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionStart`,
  `SessionEnd` and `Notification`, exec form and the `CLAUDE_PROJECT_DIR`,
  `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA` variables included;
- the repository's `.mcp.json`, after a trust prompt, and
  `lmx mcp import claude` for your user-scope servers.

What does not:

- the other hook events and the `prompt`, `http` and `mcp_tool` hook types
  (skipped with a warning); the hook fields `if`, `async`, `asyncRewake`,
  `once` and `shell`; comma-separated matchers;
- a repository's own `.claude/settings.json` hooks, which never run unless you
  pass them with `--hooks`, and `.claude/rules`;
- npm, archive and command plugin sources; LSP servers, monitors, themes,
  executables and settings in plugins; plugin options (`userConfig`).

The [compatibility table](configuration.md#compatibility-and-trust-boundary)
and the [hooks guide](hooks.md#what-is-not-supported-yet) give the details.

## Platforms

| Where | Status |
| --- | --- |
| macOS, Apple Silicon and Intel | Release archives covered by the signed checksums, and an installer; the archives are not signed or notarized by Apple |
| Linux x86-64, glibc 2.34 or newer | Release archives covered by the signed checksums, and an installer: Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, Rocky, Alma, openSUSE, Amazon Linux 2023. Needs CA certificates and `awk` |
| Windows x86-64 | Experimental. A release archive covered by the signed checksums, without an installer or automatic updates; needs Git Bash, which Git for Windows installs. Under WSL2, use the Linux build inside WSL |
| Linux arm64, musl distributions such as Alpine | No binary; use the source checkout |
| Source checkout | Wherever the pinned Erlang and Elixir build: `mise exec -- mix lmx` runs any `lmx` command |
| The library | Elixir `~> 1.19`. CI compiles it as a dependency on Elixir 1.19.0 with OTP 27, and runs the test suite on Elixir 1.19 with OTP 28 and on the toolchain `.tool-versions` pins |

Installations are per user: only the user who installed `lmx` can run and
update it, and the installer refuses to run as root unless you name a prefix.
Each release's notes state the minimum macOS version of its macOS archives.
[Installing and updating lmx](releases.md) has the install steps, the
platform notes and what the installer refuses.

Two different kinds of signing apply. Every release signs two files with the
project's Ed25519 key: the checksum list `SHA256SUMS`, which the installer
checks, and the update manifest `update.json`, which an installed `lmx`
checks. Both list each archive's SHA-256, so the archives are covered without
being signed themselves. Operating-system code signing (Apple's Developer ID
and notarization, Microsoft's Authenticode) is not done, which is why the
macOS archives should be installed with `install.sh` rather than unpacked in
Finder.

## Public API

The supported library surface is the documented functions of `Lemieux`,
`Lemieux.Supervisor`, `Lemieux.Session`, `Lemieux.Store`,
`Lemieux.Provider`, `Lemieux.Tool`, `Lemieux.Environment`, `Lemieux.Hooks`,
`Lemieux.Extension`, `Lemieux.Harness`, and the behaviours a harness selects.
`Lemieux.Testing` and `Lemieux.Providers.Scripted` ship for host tests. The
[embedding](embedding.md) and [extension](extensions.md) references say which
contract to use.

Internal modules marked `@moduledoc false`, session process state, `lmx`'s
private assembly and the terminal UI's native code are not extension APIs. Do
not depend on `:sys.get_state/1` in an extension. `lmx` itself gets no
privileged core API.

Before 1.0, a minor release may break source compatibility; the changelog
then says how to migrate. Patch releases keep documented source contracts.
This is a maintenance policy, not a promise that experimental interfaces stay
fixed.
[Transcript compatibility](transcript-compatibility.md) is versioned
separately.

## Extension bundles

A compiled extension bundle built by `mix lmx.extension.build` against a
release of Lemieux records an extension API version. It loads into an `lmx`
with the same extension API version and the same OTP major version, running
the Elixir the bundle was built with or a newer one of the same major
version. So a newer Elixir in `lmx` needs no rebuild, and an older one does.
A bundle without an extension API version, such as one built from a Git
revision that predates it, loads only into an `lmx` with exactly the
Lemieux, Elixir and OTP versions it was built with. `lmx explain` prints
those three versions. A script extension compiles in the running VM and only
has to satisfy its declared `lemieux` requirement, and the extension API
version if it names one.

## Providers

Usage and cost are reported only when they are known. A configured key or a
model catalog entry proves neither that your account may use the model nor
that a tool loop works with it; the
[validation matrix](providers.md#validation-matrix) says which provider
paths the test suite exercises. Use request limits when pricing cannot
support a dollar limit.

## Upgrading Lemieux and extensions

Read the changelog and this page before you replace a runtime. Keep the
previous binary and a copy of your session directory, and never edit a
transcript file to force compatibility.

1. Save the output of `lmx explain` to a private file. It is sanitized, but
   can still name local paths and installed tools.
2. Install the new release (an installed `lmx` usually does this itself). Run
   `lmx --version` and `lmx explain --no-user-extensions` to check the base
   runtime.
3. Run `lmx extension list`: it says, for each installed extension, whether
   this runtime would load it. Rebuild each one it refuses against the
   versions it prints: update the extension's `lemieux` dependency and lock
   file, run its tests, then `mix lmx.extension.build`. Options kept in
   `"extension_options"` in `~/.lmx/config.json` survive a rebuild; options
   kept only in a bundle's manifest do not, because a build replaces the
   whole bundle.
4. Select the extensions again and compare with
   `lmx explain --explain-against FILE`: tool names, wrappers, limits and
   extension order. This makes no model request, but selected extensions
   still run their initialization code, and gateway discovery can use HTTP.
5. Resume a copy of a session first. Check its hooks, environment and limits.
   Request and spending limits include what the session already used; raising
   a limit is a decision about the whole session, not a reset.

`--no-user-extensions` gets you past a startup that a selected extension
breaks. It does not get past a resume that needs the code which changed the
session's saved tool catalog; an embedding host can supply a replacement
catalog instead. Purely additive tools disappear when their extension is no
longer selected.

Two bundles that carry the same dependency module need compatible versions
and a fresh VM: bundles are not hot-replaced, and their dependencies are not
isolated from each other. Services belong under your host's supervision, not
in an extension's initialization.

Limits given by flag, environment variable or personal config override the
ones a transcript recorded; with no new value, the recorded limits survive a
resume. An embedding host owns its policy and must supply its limits again.
Callbacks, tool structs, credentials and environments are never restored from
a transcript as executable authority.

To roll back, restore the older binary and the matching bundles. An older
reader may refuse a transcript that newer code extended; use your copy rather
than deleting entries it does not know. See the
[schema rules](transcript-compatibility.md).

### Installed release updates

On macOS and Linux an `lmx` installed with `install.sh` or `install.py`
checks for a new release hourly and installs it only after its signature
verifies. A compatible update loads into the running terminal UI; otherwise
it is staged, and `lmx` asks you to restart. Save an unsent draft before
restarting, then resume the session with `lmx -c`. A source checkout
updates only when you type `/update`, which fast-forwards it with Git and
always needs a restart. See [updates](releases.md#updates-from-the-tui) for
the checks, the opt-outs and the source-checkout rules, and
[recovery and rollback](releases.md#recovery-and-rollback) for failed updates
and going back to an earlier version.

### If an install or update was interrupted

The installer and the updater take turns through a lock file,
`PREFIX/share/lmx/.update-lock` (by default
`~/.local/share/lmx/.update-lock`), which holds the process id of whoever has
it. When `lmx` says "installation is busy; retry when the update completes",
wait for the other installer or update to finish and try again. The
installer waits up to 150 seconds for the lock by itself, saying so, and then
stops with "installation is busy: an lmx update or another install is
running".

If one was interrupted, run `lmx update` or the installer again; `--replace`
is needed only when `PREFIX/bin/lmx` is not a launcher the installer wrote.
The installer reuses a version directory already on disk only when its files
match the verified archive exactly, and it reclaims a lock whose recorded
process is gone; it never takes a lock from a live process, or an empty one.

An interrupted recovery can leave `.update-lock.recovery` beside the lock. In
that case, stop every `lmx` and installer process, check that none is left,
remove `.update-lock.recovery` and an empty `.update-lock`, and run the
installer again. Never remove a lock while an installer or an update is
running.
