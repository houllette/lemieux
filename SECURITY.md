# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[Report a vulnerability](https://github.com/houllette/lemieux/security/advisories/new)
(the repository's **Security** tab, then **Report a vulnerability**). This
opens a private advisory that only you and the maintainer can read. Please do
not use a public issue, pull request or discussion for a vulnerability.

A useful report has:

- the affected version: `lmx --version`, the `lemieux` version in your
  `mix.lock`, or a commit;
- a small reproduction, preferably with the scripted provider
  (`Lemieux.Providers.Scripted`), a disposable key or a local listener rather
  than a live account;
- the boundary you expected to hold (see the [threat model](#threat-model) and
  [what lmx trusts by default](#what-lmx-trusts-by-default)) and what crossed
  it.

Leave out live credentials, private transcripts and other people's data.

You can expect an acknowledgement within 5 business days, and a triage
decision or a plan for a fix within 10. A fix ships in a new release together
with a GitHub security advisory, and a CVE where one is warranted.

If you cannot use the form, open an issue that asks for a private contact and
contains no technical detail.

## Supported versions

Lemieux is pre-1.0. Only the latest release gets security fixes; earlier
releases do not. A fix for a privately reported vulnerability is prepared in
private and reaches `main` together with its release and advisory.

| Version | Gets security fixes |
| --- | --- |
| The latest 0.x release: the `lemieux` Hex package and the `lmx` binaries | Yes |
| `main` | Yes, when the fix is published |
| Earlier releases | No; upgrade to the latest |

An installed `lmx` updates itself (see [Updates](#updates)). A library host
upgrades its `lemieux` dependency itself.

## Threat model

Lemieux runs a coding agent. It is not a security sandbox: model output is
untrusted, a repository can contain prompt injection, and tools act with real
side effects. The *host* is the program that starts the Lemieux runtime and
supplies its credentials, storage and policy: `lmx`, or your application when
it embeds the library.

| Boundary | What Lemieux provides | What the host must provide |
| --- | --- | --- |
| Model API | Credentials stay in provider configuration; a transcript has no field for them. `lmx` withholds credential-shaped environment variables from the commands, hooks, Elixir node and MCP servers it starts ([below](#guarded-by-default)) | Secret storage, egress policy, account and budget controls |
| Read, write and edit | Paths are confined to the working directory after `..`, absolute paths and symbolic links are resolved. Confinement is by path: a hard link inside the tree to a file elsewhere is written through. `write` refuses to replace a file the session has not read, or that changed since | An operating-system or container boundary when the working tree is not enough |
| Bash | A supervised, non-interactive subprocess in its own process group, with bounded output and a host-chosen environment. A timeout, a cancel or a stopped VM kills the whole group; a watchdog does it when the VM dies first. An opt-in Seatbelt or bubblewrap sandbox (`Lemieux.Environment.Sandbox`) | Command approval, and a sandbox or container when your user's full authority is too broad |
| Tool policy | Before and after hooks that deny with a reason, rewrite a call or park it for asynchronous approval, and the bundled `Lemieux.Extensions.Permissions` (off by default in `lmx`) | Tenant-aware policy, durable audit storage and an approval interface |
| Elixir evaluation | A separate BEAM node, reached over a pipe rather than Erlang distribution, with time, heap and output limits | Filesystem and network confinement; explicit trust before attaching to a live application |
| Repository content | `lmx` reads instructions, skills and commands as model context, confined to the repository. It never runs a repository's hooks or extensions, its own git runs nothing the repository's git configuration names, and the installed binary never reads its `.env` | Review what you ask an agent to do in a checkout you do not trust; prompt injection is not prevented. An embedding host that may start in an untrusted directory turns off `.env` loading ([below](#for-library-hosts)) |
| MCP | Protocol validation and host-supplied OAuth token storage. `lmx` starts a repository's `.mcp.json` servers only after you trust that file, refuses to expand secret-looking variables into it, and gives stdio servers the scrubbed environment | Trust decisions for server configuration and for the tools a server exposes |
| Hooks | A command with an explicit, scrubbed environment and a private input file, run by `bash` or `sh` (shell form) or as a program with arguments that no shell reads (exec form). A timed-out hook's process group is killed. Hooks are never discovered from a repository | Treat hook configuration as executable code and load it only from trusted sources |
| Benchmark graders | Direct argv execution without a shell | Treat manifest commands as executable code and load them only from trusted sources |
| Transcript | Versioned, append-only entries with no credential field. The JSONL store writes each transcript with mode 0600, makes a directory it creates 0700, and lets one writer at a time hold a transcript (`ID.lock`) | Store ACLs, encryption, retention, backups and tenant isolation |
| Native updates (`lmx` only) | The installed binary installs only releases whose manifest verifies against an Ed25519 key compiled into it. Nothing updates inside an embedding host | Nothing for `lmx`; an embedding host upgrades its dependency itself |

The preferred deployment shape separates the model call from tool execution:
keep provider credentials in the host VM and run only the tools inside the
restricted environment. A process boundary around the tools keeps steering,
policy and persistence in the VM while letting you turn off the tools'
network access.

Never put API keys, OAuth tokens or expanded MCP environment variables into a
manifest, a transcript, a hook payload kept by an untrusted party, or a
benchmark report. Request snapshots must redact credential-shaped parameters
and should record provider-neutral inputs rather than transport headers.

### For library hosts

Adding the `lemieux` dependency starts no Lemieux processes; your application
mounts `Lemieux.Supervisor` where it wants it. Lemieux's dependencies are
ordinary OTP applications and do start. `req_llm` starts its HTTP pool and, at
boot, loads `./.env` from the current working directory into the operating
system environment, running any `$(...)` command substitution in that file. A
host that may start in a directory it does not trust sets:

```elixir
config :req_llm, load_dotenv: false
```

With `Mix.install`, pass `config: [req_llm: [load_dotenv: false]]`. The
installed `lmx` sets this itself.

Nothing in [What lmx trusts by default](#what-lmx-trusts-by-default) applies
to an embedded session unless its host applies it.

### Example and research scripts

The scripts under `examples/` and `eval/` are not part of the Hex package or
the `lmx` binary; you run them yourself. The experiment scripts in
`examples/experiments` call a model only when you name it in a variable
(`LMX_MODELS`, `LMX_INVESTIGATORS_MODEL` and the like).
`examples/experiments/transcript_labels.exs` reads your `~/.lmx/sessions` and
refuses to start unless you pass `--allow-live` or set
`LMX_LABELS_DIGEST_ONLY=1`; with `--allow-live` it sends anonymized digests of
your sessions (prompts, a one-line summary of each tool call, truncated
answers) to two hosted models at their normal billing. The capture example
keeps its drafts out of Git and leaves secret-shaped files out of its
workspace snapshots.

## What lmx trusts by default

This is the one description of `lmx`'s trust model; other guides link here.
It covers the `lmx` terminal app, installed or run from a source checkout.
Your settings are in `~/.lmx/config.json` (see
[configuration](docs/configuration.md)). The *state directory* below is
`$LMX_HOME`, or else the directory that file is in: `~/.lmx`. Terms such as
*extension*, *scout* and *overlay* are defined in
[Words you will meet](docs/index.md#words-you-will-meet).

### Runs without asking

The permissions extension is off by default, so `lmx` runs every tool call the
model makes without asking ("full auto"). The startup notice says so: "full
auto: tools run without asking · commands are not sandboxed".

A session starts with these tools: `read`, `write`, `edit` (`apply_patch` in
its place for GPT-5-family models), `bash`, `grep`, `glob`, `todo`, `skill`
(loads the Agent Skills `lmx` found) and `delegate` (a read-only repository
scout), plus `ask_user` in the terminal UI. Web search and page fetch join
them when a Brave key is set, `elixir` with `--elixir`, and MCP tools from the
servers you configured or trusted.

**`bash` runs as your operating-system user and is not sandboxed** unless you
turn the [sandbox](#opt-ins) on. It can do whatever you can.

After a turn that edited files, `lmx` also runs the project's own check: the
first command the repository's conventions name, such as `tests/run.sh`, a
`Makefile` `test` target, `mix test`, `npm test` or `cargo test`. That command
is the repository's choice. It goes through the same permission policy as a
`bash` call, so in full auto it runs unasked. `"verify": false` turns it off,
and `--config none` without `LMX_HOME` does not run it.

### What lmx sends, and where

- **Your model provider**, or the gateway you route through (`--base-url`,
  Ixway), receives every request: your prompts, the model's answers, every
  tool result (so whatever files the agent read and commands printed), and a
  system prompt that includes:
  - the repository's instruction files (`CLAUDE.md`, `CLAUDE.local.md`,
    `AGENTS.md` or `AGENTS.override.md`, `SOUL.md`, `MEMORY.md`) and the
    names and descriptions of its skills, commands and subagent definitions
    (`.claude/agents`);
  - **your personal files, in every repository:** `~/.claude/CLAUDE.md`,
    `~/.lmx/AGENTS.md`, `~/.codex/AGENTS.md` (or
    `~/.codex/AGENTS.override.md`), `~/.lmx/SOUL.md`, `~/.lmx/MEMORY.md`,
    the skills, commands and subagent definitions under `~/.claude` and
    `~/.lmx`, the skills under `~/.codex/skills` and `~/.agents/skills`, and
    on Omarchy, the names and descriptions of Omarchy's skills. Instructions
    you wrote for Claude Code or Codex therefore reach whichever provider
    `lmx` uses.

  A skill's full text is sent when it is used, a file beside it when the
  agent loads that file, and a subagent definition's text when the agent
  delegates to it. `lmx run --bare` leaves the
  repository's files and yours out of that run; `"disabled_extensions":
  ["workspace"]` does so for every session; `--config none`, with `LMX_HOME`
  unset, reads none of your personal files.
- **TypeSafe** receives abridged conversation excerpts when Jev compaction is
  on. `lmx` bundles this extension.
  - *When:* it turns itself on when `JEV_API_KEY` is set or
    `jev_compaction.api_key` is saved in your config. It then sends one HTTPS
    request to `api.typesafe.ai` before a model request that carries long,
    older `read` results, and at most three such requests a session by
    default.
  - *What:* the Jev model name, a fixed instruction, the text of every user
    and assistant message (each longer than 500 bytes cut to its first and
    last 250 characters), the earlier summary cut the same way, and for each
    old result the tool name, its arguments (at most 500 characters, usually
    a path) and its length. It sends no tool output, but the abridged
    messages can quote files.
  - *Cost:* TypeSafe bills each request, and the cost counts against
    `--max-cost-usd`.
  - *Off:* `"jev_compaction": {"mode": "off"}` or `"disabled_extensions":
    ["jev_compaction"]`. An Ixway endpoint with a pinned Jev model takes
    TypeSafe's place. The
    [Jev compaction README](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/jev_compaction/README.md)
    has the details.
- **Brave Search** receives the agent's search queries when a Brave key is set
  (`BRAVE_SEARCH_API_KEY`). Page fetch then reaches the pages the model asks
  for, and refuses loopback, private and link-local addresses.
- **MCP servers** you configured, installed with a plugin, or trusted from a
  repository's `.mcp.json` receive the calls the model makes to them.
- **GitHub** receives the installed binary's update checks (see
  [Updates](#updates)).
- **A local Ollama daemon** (`http://localhost:11434`, or the base URL you
  set for an `ollama:` model) is asked which models it serves each time the
  terminal UI starts, whatever provider you use, to fill `/model` and
  `/provider ollama`. It is also asked about a model, and the context window
  it serves it with, when `lmx` picks a model with no key set or uses an
  `ollama:` model.
- **Ollama Cloud** (`https://ollama.com/api/tags`) is asked for its model
  list each time the terminal UI starts while an Ollama Cloud key is set
  (`OLLAMA_API_KEY`, or a saved `providers.ollama_cloud.api_key`); the
  request carries that key.

### Guarded by default

- **The installed `lmx` never reads a `.env` from the directory it starts
  in.** `req_llm` would otherwise load it before any trust prompt, permission
  mode or sandbox exists, running any `$(...)` in it, so a cloned repository
  could run commands on `lmx --version` or send your key to an address it
  chose. Keep keys in your environment or in `~/.lmx/config.json`. A source
  run from the checkout's root (`mise exec -- mix lmx`) still loads the
  checkout's own `.env`.
- **Repository content stays inside the repository.**
  - An `@path` import in a repository's `CLAUDE.md` or `CLAUDE.local.md` is
    followed only to a file whose real path, with symbolic links resolved, is
    inside the repository. Your own instruction files may also import from
    your home directory.
  - A repository's instruction, persona and memory files, skills, commands,
    subagent definitions and `.lmx/harness.json` are skipped when they are
    symbolic links that lead out of the repository.
  - No instruction file's import, yours or the repository's, and no
    repository file's symbolic link reaches a credential location:
    `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config/gh`, `~/.docker`,
    `~/.kube`, `~/.lmx`, `~/.lemieux`, `~/.config/gcloud`, `~/.azure`,
    `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`,
    `~/.claude/.credentials.json` and `~/.codex/auth.json`, in any letter
    case.
  - Each refusal is one notice that names the file. Unlike Claude Code,
    `lmx` does not offer to approve an import from outside the repository;
    it refuses it.
- **A repository's learned overlay can only add text, and says so.** A
  repository's `.lmx/harness.json` may add system-prompt text, and a notice
  names it on every start. Tool descriptions in it are dropped with a notice:
  only your own `~/.lmx/harness.json` may describe tools. The file's `sha256`
  shows it is intact, not who wrote it.
- **Repository code never runs on its own.** A repository's Claude Code hooks
  (`.claude/settings.json`) are not executed; pass `--hooks` for hooks you
  trust. A skill's own hooks and the shell commands it embeds are not
  executed. Extensions are never loaded because a repository names them, and
  plugins load only when you install or name them.
- **Repository MCP servers wait for trust.** A repository's `.mcp.json`
  servers start only after you trust that file.
  - The terminal UI asks once, listing each server's command or URL and the
    environment variable names it reads. `lmx mcp trust --yes` records the
    same decision, and `--project-mcp` trusts the file for one run. `lmx run`
    never asks: untrusted servers do not start.
  - A decision, yes or no, is keyed by the workspace path and a digest of the
    file, so an edited `.mcp.json` asks again.
  - A repository's configuration may not expand secret-looking variables
    (names containing `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`)
    unless you approved them when trusting it.
  - A repository server with the same name as one of your own
    (`"mcp_servers"` or `--mcp-config`) is neither started nor asked about;
    yours is.
  - Servers nobody has shown you, from `--mcp-config` or trusted for one run
    by `--project-mcp`, are announced at startup (HTTP servers by host only,
    since a query string can hold a token).
- **Credentials are withheld from subprocesses, by name.** Environment
  variables whose names contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or
  `PASSWD`, in any case, are removed from the environment of `bash`,
  background commands, the post-edit check, command hooks, the Elixir
  evaluation node and MCP stdio servers. The rule reads names, never values,
  so these still pass: a password inside a connection string
  (`DATABASE_URL=postgres://user:pass@host/db`), `MYSQL_PWD`, `GITHUB_PAT`,
  `SLACK_WEBHOOK`, and variables that point at credential files
  (`GOOGLE_APPLICATION_CREDENTIALS`, `KUBECONFIG`, `SSH_AUTH_SOCK`).
  `"credential_allowlist"` passes named variables (or `NAME_*` patterns)
  through; `"scrub_credentials": false` turns the rule off. Variables that a
  hook's or an MCP server's own configuration sets are kept.
- **Commands get your environment, not the bundled runtime's.** Commands the
  agent runs, command hooks and MCP stdio servers inherit the environment
  you started `lmx` in, less what the rule above withholds, and the editor
  Ctrl-G opens inherits all of it. Under the installed `lmx` that is your
  environment as you had it: your own `PATH`, so your own `erl`, `elixir` and `mix` run, and none of
  the variables the release sets for itself (`BINDIR`, `ROOTDIR`, `EMU`,
  `PROGNAME`, `RELEASE_*`, the `ERL_CRASH_DUMP` and `ELIXIR_ERL_OPTIONS` it
  chose, and the launcher's own `LMX_*`). A variable you set yourself before
  starting `lmx` is passed on unchanged. The Elixir evaluation node
  (`--elixir`) is the exception: it runs on `lmx`'s own runtime. From a
  source checkout, commands inherit the environment `mix lmx` runs in,
  including anything it loaded from the checkout's `.env`.
- **`write` does not replace what the session has not seen.** An existing file
  must have been read or written in this session, and be unchanged since,
  before `write` replaces it; `edit` and `apply_patch` say when a file changed
  since it was last read.
- **Changes can be undone, within limits.** `/undo`, `/rewind N` and `/redo`
  restore from two records:
  - Before `write`, `edit` or `apply_patch` changes a file, its previous
    contents (up to 10 MB a file, `.env` files included) are saved per turn
    under the state directory's `checkpoints/`.
  - When the working directory is a git repository, each `bash` command, the
    `elixir` tool and the post-edit check are bracketed by git snapshots:
    unreferenced objects in the repository's own `.git/objects`, built from
    a private index, that never touch your branches, index, stash or refs.
    Taking and restoring them runs nothing the repository configures (next
    item).

  A file changed after the agent changed it is left alone and named. A file
  you save while an agent command or the post-edit check runs is undone with
  it; `/redo` takes that back.
  - *Named, but not put back:* ignored files, and untracked files over 1 MB
    or past the first 2,000, that a command changed; tracked files that git
    stores through a filter driver (Git LFS, git-crypt, `nbstripout`) and
    that a command changed, because undo runs no filter (what `write`, `edit`
    or `apply_patch` did to them is put back as usual); commands run outside
    a git repository, in a directory the repository ignores, or in a
    repository whose `core.worktree` points at another directory; what
    background commands change later; MCP tool calls; commits and branch
    moves (`HEAD` and refs are never moved back).
  - *Not recorded at all:* what command hooks change, what a command changes
    inside an ignored directory or inside a git submodule, and anything
    outside the repository.
  - *Off:* with `--config none` and `LMX_HOME` unset, with
    `"disabled_extensions": ["checkpoints"]`, or with no writable state
    directory, nothing is recorded.
  - *Kept:* saved contents stay in `checkpoints/` until you delete them, and
    the snapshots until `git gc` prunes them.

  [Taking changes back](docs/everyday.md#taking-changes-back) has the full
  list.
- **`lmx`'s own git runs nothing a repository configures.** Snapshots and
  `/undo`'s restores run `git` on your machine, outside any sandbox, in a
  repository the agent's commands can write. So they run it with a git
  directory of their own, made for each run under the state directory's
  `checkpoints/SESSION/git/` and removed afterwards; `--sandbox` hides it
  from commands when the state directory is a directory of its own, as
  `~/.lmx` is ([Opt-ins](#opt-ins)). The repository's `.git/config`, hooks
  and `info/` are read only as data, and nothing they name runs: no hook, no
  `core.fsmonitor`, no clean, smudge or process filter, no submodule's own
  configuration. What git prints as a warning is not read as part of its
  answer, and a repository whose `core.worktree` points at another directory
  is not snapshotted. `/diff` and the search tool's file listing are
  different: they run `git` as ordinary commands in the session's
  environment, inside the sandbox when it is on, with fsmonitor, external
  diff drivers and textconv turned off; a clean filter the repository
  configures can still run there, as it would for any git command the agent
  runs. The startup git status and the A2A server's dirty
  check run the same way, but make their private git directory in the
  system's temporary directory; the status is taken as a session starts,
  before any of its commands run. `/doctor`'s undo row and the revision a
  delegated scout or the A2A server records ask the repository itself only
  where it is and which commit it is on, reading no file contents, with
  hooks, `core.fsmonitor` and transports turned off.
- **Commands cannot wait on you, and stopping one stops all of it.**
  Commands run non-interactively (no pager, git prompt or editor) in their
  own process group, so nothing they start can read the terminal the
  interface is drawn on. A timeout, a cancel, Ctrl-C, a closed terminal or a
  stopped `lmx` kills the whole group, children included, and a watchdog kills
  it when the VM dies first. Two gaps remain: a command that finishes by
  itself can leave behind processes it started in the background, and a
  `SIGKILL` sent to `lmx`'s own process group (`kill -9 -PGID`) kills the
  watchdog too, so the command runs on.
- **Clicking a file in the transcript never runs it.** Links open in your
  browser. A local file of a type that launches, installs or runs code
  (`.app`, `.command`, `.sh`, `.exe`, `.bat`, `.ps1`, `.jar`, `.pkg`, `.dmg`
  and others) is refused, text opens in a text editor, and anything else is
  shown in its folder.

### Opt-ins

- **Permissions** (`--permission-mode MODE` or `"permissions": {"mode":
  ...}`): `ask`, `accept_edits`, `auto` (inside a sandbox, commands and file
  edits run unasked; without one it is `accept_edits`), `full_auto` or
  `read_only`, with Claude Code-style `allow`, `deny` and `ask` rules; deny
  always wins. The post-edit check is asked about like any `bash` call. In
  `lmx run` nobody can answer, so a call that would ask is refused. See
  [hooks and policy](docs/hooks.md) and `lmx help permissions`.
- **Sandbox** (`--sandbox` or `"sandbox"`): commands run inside macOS Seatbelt
  or Linux bubblewrap. They can write only to the working directory, the
  temporary directories, the common tool caches and the paths `"writable"`
  adds, and reach no network beyond loopback unless `"network": true`. It
  hides these paths from commands and from the file tools, which answer
  "permission denied" (searches skip them):
  - `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.git-credentials`,
    `~/.config/git/credentials`, `~/.pypirc`, `~/.config/gh`,
    `~/.config/gcloud`, `~/.azure`, `~/.docker`, `~/.kube`,
    `~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.lmx` and
    `~/.lemieux`;
  - wherever this run keeps its config file, state directory, transcripts and
    MCP tokens, which `--config`, `LMX_HOME`, `--sessions-dir` and
    `--credentials` can move;
  - whatever `"hidden"` adds.

  That is the whole list, and `lmx help sandbox` prints it. Other
  credentials stay readable unless you add them to `"hidden"`: `~/.npmrc`
  and `~/.hex/hex.config`, for example, which `npm install` and
  `mix deps.get` read. An entry that is a file hides only that file, so the
  rest of `~/.config/git`, `~/.codex` and `~/.claude` stays readable. Only
  paths that exist when the sandbox starts are hidden. The sandbox does not
  cover the Elixir evaluation node, MCP servers, hooks or the web tools, and
  `lmx`'s own git runs outside it, running nothing the repository configures
  ([above](#guarded-by-default)). A sandbox you asked for that cannot start
  stops `lmx` rather than running without it.

  Where `lmx` keeps its own files decides how much of them is hidden. A
  location that also holds other things, such as a project's `config/`
  directory with the config file in it, has only `lmx`'s own files hidden. One
  that is or holds the working directory, your home directory, a temporary
  directory or `/` is not hidden: only a config or token file kept there is,
  on its own, and of a state directory there, only its prompt history, MCP
  trust decisions and permission rules. So with `--config ./lmx.json`, or a
  config file directly in your home, and `LMX_HOME` unset, the state
  directory's `checkpoints/` (saved file contents, and the private git
  directories `lmx`'s own git works in), `plugins/` and `state.json` stay
  readable to commands and the file tools, and writable when they are in the
  working directory or a temporary directory. When you sandbox a run whose
  config file is not in a directory of its own, set `LMX_HOME` to one.

  Your own git is not protected. A sandboxed command can write the working
  repository's `.git/config` and `.git/hooks`; `lmx`'s own git ignores what
  it writes there, but the `git` you run afterwards does not. After a
  sandboxed session in a repository you do not trust, check `.git/config`
  and `.git/hooks` before you use git in it.
- **Hooks** (`--hooks FILE` or `"hooks"`): command hooks you trust, in `lmx`'s
  format or Claude Code's settings format. See [hooks](docs/hooks.md).
- **Plugins** (`lmx plugin install`): installing a plugin is the decision to
  trust it. Its hooks run and its MCP servers start in every session.
  `lmx plugin install GIT-URL` makes a shallow clone into
  `~/.lmx/plugins/NAME` that runs nothing from the repository. Marketplaces,
  and the plugins they list, are fetched with Git (a `marketplace.json` URL
  is downloaded directly) into your user cache (`~/Library/Caches/lemieux`
  on macOS, `~/.cache/lemieux` on Linux) and refreshed at most hourly; an
  entry pinned to a commit (`sha`) is always checked out at that commit.
  Each plugin's data directory, `~/.lmx/plugin-data/ID`, is private (0700).

### Updates

The terminal UI of an `lmx` installed with `install.sh` or `install.py` checks
for updates and, on macOS and Linux, installs them. An archive you unpacked
yourself and the Windows build (experimental) announce a new release but do
not install it. `lmx run`, a source checkout and an embedding host never
check on their own.

- **When:** after the first session is ready, after `/new` and `/resume`, and
  hourly while the terminal UI is open.
- **What it requests:** `update.json` from the latest GitHub release; only
  when that names a newer stable version, the version's `update.json.sig`,
  then the archive for your platform. The requests carry the user agent
  `lemieux/VERSION`, so GitHub sees your IP address and your `lmx` version.
- **What it trusts:** nothing is staged until `update.json.sig` verifies as an
  Ed25519 signature by the key compiled into the running binary, and staging
  verifies it again. The archive must match the signed SHA-256 and carry a
  release identity that matches the signed entry. Only a strictly newer
  stable version is offered, so a replayed older manifest cannot downgrade
  you. An unsigned or altered manifest is never installed; the terminal UI
  warns once per version.
- **What it does:** installation is automatic. A compatible update loads
  into the running terminal UI, with a health check and rollback; otherwise
  it applies at the next start.
- **Opting out:** `LMX_CHECK_UPDATES=0` stops the automatic checks; `/update`
  still checks when you type it. `LMX_AUTO_UPDATE=0` keeps the notices but
  installs only when you type `/update`, after the same verification.
  Selecting your own extensions also turns automatic installation off.

The maintainer keeps the signing key offline, and the release workflow never
signs, so a compromised workflow, token or account that can upload release
assets cannot produce an update that `lmx` will install. Signing does not
cover your first download of the installer, which trusts HTTPS and GitHub
unless you [verify it](docs/releases.md#verify-a-download), or a compromise
of the maintainer's offline key.
[Installing and updating lmx](docs/releases.md#updates-from-the-tui) has the
details.

### Where lmx keeps its data

| Path | What it holds |
| --- | --- |
| `~/.lmx/config.json` | Settings, personal MCP servers, saved plugin selections and, if you saved them, provider keys in plain text (mode 0600) |
| `~/.lmx/sessions/ID.jsonl` | Transcripts: prompts, answers and everything tools read or printed (mode 0600). A sessions directory `lmx` creates is 0700; one that already exists, such as a shared directory named with `--sessions-dir`, keeps its mode |
| `~/.lmx/sessions/ID.lock` | The `lmx` process that has a transcript open; a second one is refused with the holder's process and host. A lock is taken over only when its holder is provably gone, never from another host: delete it yourself then |
| `STATE/checkpoints/` | File contents saved for `/undo`, `/rewind` and `/redo` (`.env` included), what each undo replaced and what a forced redo overwrote; kept until you delete them. While a snapshot or an undo runs, it also holds that run's private git directory (`SESSION/git/`) |
| `STATE/trusted-mcp.json` | Repository `.mcp.json` trust decisions, by workspace path and file digest (`lmx mcp untrust` forgets one) |
| `STATE/permissions/DIGEST.json` | "Always allow" answers, per repository |
| `~/.lmx/mcp-credentials.json` | MCP OAuth tokens (mode 0600), unless `--credentials` or `LMX_CREDENTIALS` names another file. The first time `lmx` uses it, it moves in the tokens from the library's default file, `~/.lemieux/credentials.json` |
| `STATE/logs/lmx.log` | Log lines, errors only unless `LMX_LOG_LEVEL` says otherwise (directory 0700; rotated at 1 MB, three old files kept). Setting `LMX_LOG_LEVEL` also copies them to standard error, never over the terminal UI's screen. At `warning` and below, failed requests can log provider response headers, cookies included |
| `~/.lmx/crash/erl_crash.dump` | A crash dump, unless `ERL_CRASH_DUMP` names another file (directory 0700; `$LMX_HOME/crash` when that is set, whatever `--config` or `LMX_CONFIG` say). The installed `lmx` and every command run from a source checkout (`mix lmx`, `mix lmx.tui`) point dumps here before the command does anything else, `--config none` included |

`STATE` is the state directory, `~/.lmx` unless you moved it, and `lmx`
creates it with mode 0700. `--config none` with `LMX_HOME` unset has no
state directory: nothing in the `STATE` rows is written. It still keeps
transcripts and MCP tokens at the paths above, and points crash dumps at
`~/.lmx/crash`, which it creates.
[Storage locations](docs/configuration.md#storage-locations) lists everything
else `lmx` stores.

A crash dump holds whatever the VM held: provider keys and transcript text
included. Under the installed `lmx`, the commands the agent runs do not
inherit the `ERL_CRASH_DUMP` that `lmx` chose for itself, so an Erlang or
Elixir program of yours that crashes writes its dump where it would without
`lmx`; if you set `ERL_CRASH_DUMP` yourself, `lmx` and your commands both
use your value. From a source checkout, commands inherit the source run's
setting, so such a program writes its dump to the same file, or, under the
sandbox, which hides `~/.lmx`, writes none. Never attach a crash dump, a
transcript or a debug log to a public issue: they can contain source,
prompts, tool output and secrets a tool happened to read.

### The runtime

The installed `lmx` runs without Erlang distribution: it opens no
distribution port, and no cookie ships in an archive. `RELEASE_DISTRIBUTION=sname`
(or `name`) opts in for the underlying `bin/lmx-release` script; without
`RELEASE_COOKIE`, the first such start writes a random cookie for that
installation, readable by its owner only. The Elixir evaluation node is
reached over a pipe and needs no distribution either.

Native extensions you load run trusted code in the `lmx` VM; version checks
and collision detection are not a sandbox.

`lmx explain` omits credential values, headers and gateway URLs. It can still
name local paths and tools, selected extensions run their initialization code
while it prepares, and gateway discovery can use HTTP. Review its output
before you share it, and report problems with a small, sanitized
reproduction.

## Release signing key

`lmx` releases are signed with this Ed25519 public key (the base64 of its 32
raw bytes):

```text
X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=
```

Every `lmx` build and `scripts/install.py` pin the same key, and each release
tag carries it as `dist/lmx/release-signing.pub`. Compare two copies before
you rely on one. [Verify a download](docs/releases.md#verify-a-download)
shows how to check a release with it. If the key ever changes, the release
that changes it says so, and so does this section.
