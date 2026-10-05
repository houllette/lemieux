# Troubleshooting

Start with the exact sentence `lmx` prints: most of them say what to do. The
headings below quote the common ones, so you can search this page for the
words you saw.

## First checks

- **`lmx explain`** prints, as JSON, what a new session would start with: the
  versions, the model and what chose it, the route, which credentials are
  present (never their values), tools, the defaults that were applied, the
  limits and the log file. It makes no model request, though an extension's
  start-up code or a gateway lookup can still run. Credential presence is not
  proof that your account can use a model. Review paths and tool names before
  you share the report.
- **`/doctor`** in the terminal UI prints a readable version of the same
  checks for the running session: the model and key, limits, MCP servers,
  permissions, checkpoints, the sandbox and platform tools.
- **Isolate your setup** with `--config none --no-user-extensions`, which
  leaves out your config file and your own extensions. Unless `LMX_HOME` is
  set, `--config none` also ignores your provider keys and a local Ollama
  when choosing a model: it starts on `anthropic:claude-sonnet-5` unless
  `--model` or `LMX_MODEL` names another.
- **Read the log.** By default `lmx` writes log lines only to
  `~/.lmx/logs/lmx.log`. `LMX_LOG_LEVEL=debug` raises the level and also
  prints them on standard error, though never over the terminal UI's screen.
  See [Where log lines go](#where-log-lines-go).

Questions go to [GitHub Discussions](https://github.com/houllette/lemieux/discussions)
and bugs to [GitHub Issues](https://github.com/houllette/lemieux/issues).
Include `lmx --version`, the sentence `lmx` printed and the relevant log
lines. Read a log or a transcript before you share it, and never attach a
crash dump to a public issue.

## Installing and updating

### The installer refuses this system

The installer checks the system before it downloads anything. Each refusal
ends with where to go instead:

- `lmx's Linux build needs glibc 2.34 or newer; this system has glibc X.Y` —
  older distributions (Ubuntu 20.04, Debian 11, RHEL 8, Amazon Linux 2) need
  the source checkout.
- `this Linux system does not use glibc; musl distributions such as Alpine are
  not supported` — use the source checkout.
- `there is no Linux arm64 build yet` — use the source checkout, including in
  a Linux VM or container on Apple silicon.
- `this installer is for macOS and Linux` (from Git Bash, MSYS or Cygwin on
  Windows) — the Windows build is experimental and needs Git Bash: unpack
  `lmx_windows.tar.gz` and run `bin\lmx.cmd`, or `bin/lmx` from Git Bash
  ([Windows (experimental)](releases.md#windows-experimental) has the
  steps). In WSL2, run the installer inside WSL to get the Linux build.
- `lmx installation needs Python 3.8 or newer` (from `install.sh`), or
  `lmx's installer needs Python 3.8 or newer (found X.Y)` (from `install.py`
  run directly) — install a newer Python 3. `install.sh` takes the first
  suitable `python3` on `PATH`; `LMX_PYTHON` names another, as in
  `curl -fsSL …/install.sh | LMX_PYTHON=/usr/bin/python3.11 sh`. If that one
  is too old or does not run, `install.sh` says `LMX_PYTHON is set to …,
  which is not a Python 3.8 or newer that runs here`.
- `lmx installs per user, and an installation made as root can only be run
  and updated by root` — you ran it with `sudo`. Run it again as the user who
  will run `lmx`. If root itself will run `lmx` (in a container, say), pass
  `--prefix` explicitly.

The source checkout is described in [First session with
lmx](getting-started.md).

### `warning: no CA certificates found`

On Linux, `lmx` trusts the system's certificate bundle and has no other trust
store. The installer warns when it finds none
(`/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt` and
the like) and installs anyway, but every HTTPS request `lmx` makes would then
fail. Install your distribution's `ca-certificates` package; slim container
images (`debian:*-slim`, `ubuntu`) often lack it.

### `A release without SHA256SUMS.sig is unsigned`

Every release is signed with the maintainer's offline Ed25519 key, and the
installer checks that signature before it installs anything. `install.sh`
stops when the latest release has no signature, because `lmx` does not install
unsigned releases. Wait for the signed release, or check a download yourself
as [Verify a download](releases.md#verify-a-download) in *Installing and
updating lmx* describes. The installer prints `Signature and checksum
verified` when both checks passed.

### macOS blocks the downloaded binary

The macOS builds are not signed by Apple. Install them with `install.sh` or
`install.py`, which leave no quarantine flag on what they install. An archive
you downloaded in a browser and unpacked in Finder carries macOS's quarantine
flag on every file, and Gatekeeper blocks the runtime file by file. Install
that archive with `install.py` instead, which is published beside the archives
in every release:

```sh
python3 install.py ~/Downloads/lmx_macos_silicon.tar.gz \
  --checksums ~/Downloads/SHA256SUMS --signature ~/Downloads/SHA256SUMS.sig
```

### An update was not installed

The installed `lmx` installs an update only after its signed manifest
verifies against the public key built into the binary. When it does not, the
notice box says why:

- `lmx vX is available, but its update manifest is not signed yet, so lmx
  cannot verify it and did not install it` — nothing to do: `lmx` keeps running
  and treats it as an ordinary update once the signed manifest is published.
- `lmx vX was not installed: its update manifest failed signature
  verification, so the release may have been tampered with` — do not install
  that release by hand. Report it through the [security
  page](https://github.com/houllette/lemieux/security). An installation that
  missed a change of the signing key sees this too; that release's notes say
  to reinstall with `install.sh`.
- `lmx vX is available. This build has no release-signing key, so it cannot
  verify updates and will not install them` — download the new version from
  the releases page and reinstall it.
- `The update carried no verified signature, so it was not installed` (after
  `/update`) — `/update` checks again.

`LMX_AUTO_UPDATE=0` keeps the notices but installs only when you run
`/update`; `LMX_CHECK_UPDATES=0` turns the automatic checks off, and
`/update` still checks. An `lmx` you unpacked by hand, and the experimental
Windows build, say when an update is available but never install one
themselves; `/update` then says `Download an update from
https://github.com/houllette/lemieux/releases and restart lmx. On macOS and
Linux, install lmx with install.sh to get automatic updates.`

### `lmx: this installation belongs to another user`

An installation belongs to the user who installed it, and the launcher stops
at once, with status 1, when it cannot use one:

- `lmx: this installation belongs to another user; reinstall it as yourself
  with install.sh`
- `lmx: DIR is not writable; lmx records each launch there`
- `lmx: the installation at DIR is missing; reinstall it with install.sh`
- `lmx: cannot create LOCK; check that you own this installation and can
  write to it` (a permission problem or a read-only file system)

If you deleted an installation but its `~/.local/bin/lmx` shim remains, the
shell reports `not found`: reinstall, or remove the shim.

### `awk: command not found` when lmx starts

The Linux archive's start scripts use `awk`. Every full installation has it,
but some slim container images do not, and there each start prints a line
such as `env.sh: line 680: awk: command not found`. `lmx` still runs. Install
your distribution's `gawk` or `mawk` package to make the line go away.

### Windows: `no bash was found`

The Windows build is experimental. Commands run in Git for Windows' bash:
install [Git for Windows](https://gitforwindows.org/) and start `lmx` from Git
Bash. `lmx` never uses WSL's `bash.exe`, because it would run commands inside
the Linux distribution, on `/mnt/c` paths, without `lmx`'s credential scrub
or process cleanup. To work in WSL2, install the Linux build inside WSL. On
native Windows, Ctrl-G cannot open an editor yet, and hooks need Git Bash too.

## Starting lmx

### `no model credentials found` or `no API key for …`

`lmx run` stops with status 3 before any session exists, after any
configuration warning that explains it (`ollama:llama3.2, the model you last
chose, is not available …`):

- `no model credentials found: set a provider's API key, such as
  ANTHROPIC_API_KEY or OPENAI_API_KEY …` — nothing named a model and no key
  or local model was found. Set a key, start Ollama with a model that can call
  tools ([Use a local model](providers.md#use-a-local-model)), or pass
  `--model PROVIDER:MODEL`. Bare `lmx` in a terminal opens a panel that saves a
  key for you.
- `no API key for openai: set OPENAI_API_KEY, or choose another model with
  --model PROVIDER:MODEL` — a flag, `LMX_MODEL` or the config file named a
  model whose provider has no key.
- `--config none starts on anthropic:claude-sonnet-5 and picks no model from
  your keys or a local Ollama` — set `ANTHROPIC_API_KEY`, or pass `--model`.

In the terminal UI, the *Choose a model provider* panel opens instead. Esc
closes it with `no key saved · set one in your environment, or paste it here
at the next start`, and names the `/provider` switches that work now, such as
`/provider ollama`. A prompt sent without a key then says `no provider key
was found` and how to get one; restart `lmx` to see the panel again. For a
model you named, or a session you resumed (`lmx -c`, `lmx --resume ID`), the
panel names that model, and a prompt without its key fails with `no API key
for PROVIDER · set VARIABLE, or switch with /provider`. `/provider` saves no
key: paste one into the panel, or set the variable, and start again.

Set the variable in the environment that launches `lmx`, then open a new
shell (or restart the process manager that starts it). The installed `lmx`
does not read `.env` files. A variable set to an empty value counts as no key
and also switches off a key saved in `~/.lmx/config.json`; `lmx help models`
lists the variables.

### `… is not a model specification`

Models are written `PROVIDER:MODEL`. `lmx` checks the name before it starts a
session, and stops with status 2:

- `gpt-4o is not a model specification: write PROVIDER:MODEL, for example
  anthropic:claude-sonnet-5 (lmx help models)` — add the provider.
- `X names a provider lmx does not know (P); lmx help models lists the usual
  ones` — check the spelling of the provider.
- `X is not a model lmx can reach: …` — the provider does not offer that name,
  or not to your account. `/provider` and `/model` in the terminal UI list
  what your keys can reach.

For Ollama, use the full tag `ollama list` shows, quantization included
(`--model ollama:qwen3.8:27b-mxfp8`). For Ollama Cloud, set `OLLAMA_API_KEY`
and use `ollama_cloud:MODEL`.

### `… is not a command` or `unexpected argument`

`lmx` takes a prompt through `lmx run`, through `lmx --prompt`, or in the
terminal UI once it is open:

- `lmx "fix the bug"` says the quoted words are not a command, and shows the
  `lmx run` and `lmx --prompt` lines that would take them.
- `lmx tui fix the tests` says `unexpected argument "fix": the terminal UI takes
  a prompt only through --prompt: lmx --prompt 'fix the tests'; or answer it
  without the terminal UI: lmx run …`.
- `run needs a prompt: lmx run "what should I do?", or pipe one in`.
- `--model does not apply to lmx log`: a flag that belongs to another command
  is named as such.

From a source checkout, every one of these says `mix lmx` instead of `lmx`.

### `no stored session has the id or name …`

The name or id does not match a transcript in the sessions directory `lmx` is
using (`~/.lmx/sessions`, or `--sessions-dir`, `LMX_SESSIONS_DIR` or
`"sessions_dir"`). `/resume all` in the terminal UI lists every directory's
sessions; `lmx help sessions` says where they live. Old session names still
resolve.

### `this session is open in another lmx`

A transcript is written by one `lmx` at a time. The message names the process
(its pid, host and since when): close it there. A lock left by a process that
is provably gone is taken over on its own; if the message still names a
process that no longer exists, or one on another host, delete the lock file it
names and try again.

### The terminal UI says it needs an interactive terminal

`the terminal UI needs an interactive terminal, and could not claim one … Run
lmx in a terminal window, or use lmx run PROMPT from scripts, pipes and CI.`
The terminal UI needs a real terminal; started from a pipe, a non-interactive
runner or CI, it exits with status 1. Use `lmx run` there, or an embedding
host with an `ex_ratatui` session or SSH transport.

### `the terminal UI's native library is not in a real priv directory`

The terminal UI's native library ships inside the release archive. This
message means the installation or the source build is incomplete. Reinstall
the archive for your operating system and CPU, or, from a source checkout:

```sh
mise exec -- mix deps.get
mise exec -- mix lmx
```

### The source checkout will not build

Install the Erlang and Elixir versions `.tool-versions` pins, then fetch and
compile:

```sh
mise install
mise exec -- mix deps.get
mise exec -- mix compile
```

`asdf install` works instead of `mise install`. On macOS and Ubuntu, `mise`
downloads a prebuilt Erlang; elsewhere it compiles Erlang, which takes a few
minutes and needs a C toolchain and the OpenSSL and ncurses headers. Without
the OpenSSL headers the Erlang build still finishes, and `mix deps.get` then
fails with `module :crypto is not available`. Install these first:

| Distribution | Packages |
| --- | --- |
| Debian, Ubuntu | `build-essential autoconf m4 libssl-dev libncurses-dev unzip git curl` |
| Fedora, RHEL, Rocky, Alma | `gcc gcc-c++ make autoconf openssl-devel ncurses-devel perl unzip git` |
| Arch | `base-devel openssl ncurses unzip git` |
| openSUSE | `gcc gcc-c++ make autoconf libopenssl-devel ncurses-devel unzip git` |

You do not need to run the test suite to use `lmx`; [CONTRIBUTING](../CONTRIBUTING.md)
covers development checks.

## Network and providers

### `could not reach PROVIDER at ORIGIN (REASON)`

The connection never opened. `lmx run` names where it was going (the scheme,
host and port only) and the likely fix:

```text
lmx: could not reach ollama at http://localhost:11434 (connection refused): is Ollama running? Start it with `ollama serve`, or choose another model with --model
```

The terminal UI says the same without the address, and offers `/retry`. The
reason is one of `connection refused`, `the host name did not resolve`, `no
route to the host`, `the network is unreachable`, `the host is down`, `the
network is down` or `the address is not available`. A refused connection means
nothing is listening: start the local server, or check what `--base-url`
points at. Anything else is the road there: `are you offline, or behind a
proxy?` (see the next section).

### Proxies and private certificate authorities

`lmx` does not read `HTTP_PROXY`, `HTTPS_PROXY` or `NO_PROXY` today. Model
requests, remote MCP servers, Ollama discovery and the update check connect
directly, so on a network that only lets traffic out through a proxy they
fail, usually with `the host name did not resolve` or `connection refused`.
`--base-url` points `lmx` at an API-compatible gateway; it is not a forward
proxy. The installer does honour the proxy variables, so installing works
where running does not.

`lmx` does not read `SSL_CERT_FILE` either. It trusts the operating system's
certificates: on Linux the distribution's CA bundle
(`/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, …),
on macOS the system keychains. To trust a company's own certificate
authority, add it to that store (`update-ca-certificates`, `update-ca-trust`,
Keychain Access). Connections use IPv4, so an IPv6-only network cannot reach
providers.

### MCP OAuth cannot return to the callback

The browser comes back to `localhost` port 8642 by default. If the browser is
on another machine, open the tunnel before you open the printed URL:

```sh
ssh -L 8642:localhost:8642 devbox
```

If the port is taken, choose another and use it consistently:

```sh
lmx --mcp-config ./mcp.json --oauth-callback-port 9864
```

Some issuers need a client id you registered by hand. The error names the
issuer for `--oauth-client-id ISSUER=ID`.

### A provider request failed

A turn ends with an error row when the provider answered with a failure and
the session's own retries did not get past it. The row says what to do for
that kind of failure: a missing key names the variable to set; an
authentication, billing or quota failure says retrying will not help; a rate
limit gives the provider's wait; a context overflow suggests `/compact` then
`/retry`; anything else offers `/retry`. What happened first depends on the
failure:

- An HTTP 5xx, a rate limit (429), an overloaded provider, a dropped
  connection or a stream that broke off is retried automatically, up to six
  attempts, waiting two seconds and doubling each time, or whatever
  `retry-after` the provider sent. The live row says `retrying in 8s (3/6)`
  while it waits, and `lmx run` writes a line on standard error such as
  `provider request failed (…); retrying in 8000ms (3/6)`.
- That includes a stream that broke off after output arrived. Tools run only
  once a response is complete, so nothing acted on the partial answer; it is
  kept in the transcript, drawn dimmed and labelled interrupted, and never
  sent to the model again.
- A failure the provider will repeat (a missing or rejected key, billing or
  quota, a rejected model, a 4xx that is not a rate limit) is not retried.
- A context overflow is recognized for Anthropic, Gemini, Bedrock and Vertex
  Claude, Z.AI and OpenAI-compatible servers: the session compacts and tries
  again, and learns the window the provider stated.

`/retry` is the manual path for all of these: it rebuilds the next request
from the transcript as it stands, tool results included, and sends it again
with nothing lost. It is refused while a turn is running and after a turn that
ended any other way, since a budget or a cancellation is not something a
retry would change. An HTML error page (a gateway's debug page, say) is
reduced to its title and first lines. Embedding hosts turn the automatic
retries off with `provider_retry: false`, or tune them with `max_attempts:`,
`base_delay_ms:` and `max_delay_ms:`.

## Local models

### A local model forgets the task or answers with nothing

Ollama serves a model with a context window sized by GPU memory unless you set
one, as small as 4,096 tokens, and it silently drops whatever does not fit,
your task first. Set `OLLAMA_CONTEXT_LENGTH=65536` (32768 at the least) for
the Ollama server, restart it, and check the CONTEXT column of `ollama ps`;
[Use a local model](providers.md#use-a-local-model) has the steps.
`--context-window` cannot fix this: it only tells `lmx` the size for planning,
and cannot change the window Ollama serves.

`lmx` asks Ollama for the window it serves and says what it learns:

- `Ollama has not said yet what window it serves MODEL with, so this session is
  planning as if it held 128.0k tokens until it does` — normal before the
  model is loaded; `ollama ps` shows the window once it is.
- `MODEL has a 4,096-token context window, and this session's own
  instructions and tools take about 3,490 of it, which leaves little room to
  work` — raise `OLLAMA_CONTEXT_LENGTH` as above.
- `summarising made no room …` — even a summary leaves the next request over
  the compaction threshold, so the session stops summarising on its own for a
  while. `/compact` still works; a larger window is the fix.

### A local model takes minutes to start answering

Ollama sends nothing while it reads a prompt, and a long prompt can take
minutes on a large local model. `lmx` waits up to 15 minutes for the first
token (and between tokens) of an `ollama:` model before it calls the stream
stalled. An answer is capped at 16,384 tokens, so a model that repeats itself
stops eventually. A smaller model, or a shorter conversation (`/compact`, a
new session), answers sooner.

### Context says `unmeasured`

That is expected before the first provider response and right after
compaction. `lmx` uses the usage the provider reports rather than guessing
with a local tokenizer, so tool results added since the last response are not
measured until the next request includes them. `/context` still shows the
session's totals.

## The terminal

### Text is invisible or very faint

`lmx` draws for a dark background unless it learns that yours is light. With
no theme chosen, it asks the terminal for its background colour before the
screen opens (most terminals answer), then reads `COLORFGBG`, then, in
Terminal.app before macOS 26, the macOS appearance. A terminal that answers
none of them gets the dark palette. Choose the palette yourself:

- `/theme light` until you quit, or `"theme": "light"` in
  `~/.lmx/config.json` for good (`"dark"` the other way);
- `/theme mono`, or `NO_COLOR=1`, for no colour at all.

A theme you chose always wins over detection, and with `"theme"` set `lmx`
does not ask the terminal at all. If the terminal's late answer to that
question shows up as stray characters in the input box at startup, setting
`"theme"` in `~/.lmx/config.json` avoids it.

### Colours look wrong

`lmx` draws its tints with the 256-colour palette unless the terminal says it
draws 24-bit colour (`COLORTERM=truecolor` or `24bit`, or a `TERM` ending in
`-direct`). Inside GNU screen it always uses 256 colours.

- Code blocks drawn as dim text on a yellow background mean the terminal was
  sent 24-bit colour it does not understand (Terminal.app before macOS 26 and
  GNU screen 4 do this). Unset a `COLORTERM=truecolor` that your terminal does
  not live up to, for example one inherited over SSH.
- Tints one step off mean 256 colours in a terminal that could draw 24-bit
  colour but does not say so: `export COLORTERM=truecolor`.

### Alt shortcuts do nothing on macOS

Alt-1 to Alt-9, Alt-E, Alt-U, Alt-Z and Alt-N need the Option key to send Alt.
Out of the box, macOS terminals type characters instead (Option-1 types `¡`).
Turn on *Use Option as Meta key* in Terminal.app (Settings > Profiles >
Keyboard), set *Left Option key* to Esc+ in iTerm2 (Settings > Profiles >
Keys), or set `"terminal.integrated.macOptionIsMeta": true` in VS Code. Under
tmux, set it in the outer terminal. `/unsteer` and the other slash commands
work in any terminal; see [Keys](cli.md#keys).

### Page Up scrolls the terminal, not the conversation

Terminal.app keeps Page Up and Page Down for its own scrollback. Use
Shift-Page Up and Shift-Page Down (Shift-Fn-Up and Shift-Fn-Down on a laptop
keyboard) or the mouse wheel.

### Shift-Enter sends the draft or clears it

Where the terminal cannot tell Shift-Enter from Enter, use Ctrl-J, or type `\`
at the end of the line and press Enter. In Ghostty, a custom
`shift+enter=text:\n` binding sends a plain Enter; replace it with
`keybind = shift+enter=csi:13;2u` and reload Ghostty's configuration.

### The terminal is garbled after lmx was killed

A process killed with `kill -9`, or a runtime that crashed, cannot leave the
full screen: the prompt appears over the old screen, the cursor is hidden, and
moving the mouse types escape codes. Type `reset` and press Enter (or run
`stty sane`, then `reset`), even if you cannot see what you type.

The installed `lmx` puts the terminal back on its own when only its runtime
died, and `kill PID` (SIGTERM) or closing the window ends it cleanly. If the
`lmx` launcher is the one killed outright, its runtime leaves the screen on
its own within about a second. The conversation up to the moment it stopped
is in its transcript, and `lmx -c` resumes it.

### Ctrl-G does not open an editor

Ctrl-G opens the draft in `$VISUAL`, else `$EDITOR`, else `vi`, and needs a
POSIX `sh` on `PATH`. It does not work on native Windows yet (WSL2 behaves
like Linux). A window editor must wait for the file to close:
`export VISUAL="code --wait"`. While the editor is open, Ctrl-C, Ctrl-Z and
Ctrl-\ are keys the editor reads rather than signals to `lmx`, and keys you
type into the waiting terminal behind a window editor reach `lmx` after the
editor closes. A terminal editor sees a window resize only when it redraws.

### Pasted text arrives as separate messages

GNU screen 4 (macOS's `/usr/bin/screen`) does not pass bracketed paste, so a
pasted block arrives as typed lines: Enter sends the first as a prompt and the
next ones as steers. Use tmux, which `lmx` supports. Under tmux, copying with
OSC 52 needs `set -s set-clipboard on` in your tmux configuration.

## Tools, checkpoints, hooks and MCP

### A tool cannot read or write a path

`read`, `write` and `edit` refuse paths outside the session's working
directory, whether through `..`, an absolute path or a symbolic link. Start
`lmx` at the right root (`-C DIR` does that from anywhere), or give an embedded
session the right `cwd`. Under `--sandbox`, a hidden path (such as `~/.ssh`,
or `lmx`'s own state) says "permission denied" to the file tools as well as
to commands. `bash` has your ordinary rights, so do not rely on it to work
around a confinement a policy expects.

### `write` refuses to replace a file

`write` replaces an existing file only after the session has read (or
written) it, and only while it is unchanged since; otherwise it asks the model
to read the file first. That stops a model from overwriting a file it never
looked at, or one you edited while it worked. The model normally reads and
retries on its own.

### `/undo` did not put something back

`/undo` takes back what the last turn changed that was recorded: what
`write`, `edit` and `apply_patch` changed (files up to 10 MB) and, in a git
repository, what commands and the post-edit check changed in tracked files
and in untracked files up to 1 MB. Its report names what it could not put
back, such as commands run outside a git repository, ignored files like
`.env` that a command changed, MCP tool calls, commits and branch switches.
Files a command changed outside the repository it ran in (your home
directory, say) are neither put back nor named.
[Taking changes back](everyday.md#taking-changes-back) has the full list.
Other answers:

- `/undo covers file-tool edits only here: not a git repository, so what
  commands change is not recorded` — said once, in the notice box at
  startup (and by `lmx run` at its first command), when the working
  directory is not in a git repository. The same notice names a missing
  `git`, a directory the repository ignores, or a repository whose work
  tree is set to another directory (`core.worktree`), which undo does not
  snapshot. Start `lmx` inside an ordinary git repository to have commands
  recorded too; `/doctor` shows what `/undo` covers there.
- `could not restore: PATH (changed while a command ran; git passes it
  through a filter (Git LFS, git-crypt), which undo does not run, so undo
  does not save it)` — a command changed a tracked file that git stores
  through a filter driver. Undo runs no filter, so it never saved that
  file's contents: restore it with your own git and its LFS or git-crypt
  tools. What `write`, `edit` and `apply_patch` changed in such a file is put
  back as usual, and a file marked `-filter` is undone like any other.
- `not undone yet · a command you stopped is still being recorded · /undo
  again in a moment` — run it again shortly.
- `no checkpoints are recorded in this session, so there is nothing to put
  back` — checkpoints are off: `--config none` without `LMX_HOME`, or
  `"disabled_extensions": ["checkpoints"]`.
- `nothing to undo · checkpoints could not be written to PATH` — make that
  directory writable to record the next turn.
- A file changed since the agent changed it is left alone and named;
  `/undo --force` puts it back anyway.

### A hook failed but the tool still ran

Ordinary hook failures (it did not start, timed out, printed invalid JSON, or
exited with a status other than 0 or 2) warn and let the call go ahead. A
policy that must block has to:

- exit 2 and write the reason to standard error; or
- exit 0 with JSON such as `{"decision":"deny","reason":"..."}`, or Claude
  Code's `{"hookSpecificOutput": {"permissionDecision": "deny",
  "permissionDecisionReason": "..."}}`.

Matchers ignore case and know Claude Code's tool names (`Bash`,
`Edit|Write`); a comma list such as `Edit, Write` matches nothing. `lmx` does
not warn about a matcher that names no tool in the session, which is the
usual reason a hook never runs, so make a new guard refuse one call before
you rely on it. Only standard output is read as JSON. A hook's
`systemMessage` is logged as a warning, so it shows only with
`LMX_LOG_LEVEL=warning` or lower. See [Hooks](hooks.md#command-protocol).

### A command the agent runs is missing a variable

Commands, hooks and MCP stdio servers do not receive variables whose names
contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`, so a command that
needs one (`gh` reading `GH_TOKEN`, a publish step reading `NPM_TOKEN`) runs
as if it were unset. Name it in `"credential_allowlist"` (`["GH_TOKEN"]`, or
a pattern such as `"NPM_*"`), or set it in a hook's or an MCP server's own
`env`; see [Credential scrubbing](configuration.md#credential-scrubbing).
Everything else comes from the environment you started `lmx` in. Under the
installed `lmx` that includes your own `PATH`, so your `erl`, `elixir`,
`mix` and `iex` run as they do in your shell; [What commands
inherit](configuration.md#what-commands-inherit) lists what is left out.

### An MCP server has no tools

Run `/mcp` to see each server's state and its connection error. A server that
needs OAuth shows "needs sign-in": select it and press `r`, which opens the
browser. Otherwise check the command or URL outside `lmx`, then reconnect. A
server that fails to start stays listed with no tools and does not take
tools away from healthy servers. A slow server gets its `startup_timeout` (one
minute by default) before it counts as failed; a `"type": "sse"` entry is
refused with a message saying to use the server's streamable HTTP endpoint;
and a tool whose name a provider would refuse is offered under a valid, hashed
name, which `/mcp` shows. For stdio servers, the `env` object adds to the
process environment, `${VAR}` expands when the server connects, and
credential-shaped variables are withheld unless `credential_allowlist` names
them.

### A repository's MCP servers did not start

They wait for you to trust them. The terminal UI asks. From a shell, run
`lmx mcp trust` to see what they would run, then `lmx mcp trust --yes`.
`--project-mcp` starts them for one run, and `--no-project-mcp` never does.
Under `--config none` without `LMX_HOME` there is nowhere to remember
trust, so only `--project-mcp` starts them.

### The agent appears stuck on a question

An `ask_user` question waits for you. In the terminal UI, choose an answer (or
Other), review the set and choose Submit answers. An embedding host receives
`{:question, question}` and must answer through the session's API. `lmx run`
offers no `ask_user` tool, because nobody may be there to answer.

### `lmx explain` exits 1: two tools share a name

`lmx explain: the tool catalog offers 2 tools named NAME (A, B); leave all but
one out ("disabled_extensions" names a shipped one) or rename the others, so a
session would refuse to start`. An extension of yours adds a tool that `lmx`
already has. Leave one out, or rename yours: an extension should add what
`lmx` does not have.

### `--elixir` cannot start its node

Elixir evaluation starts another BEAM node and needs real compiled-code
directories, which the release archives have; a custom archive or embedded
host must keep the release layout. If the node still fails to start, check
that `epmd` can run and that your user can start local distributed Erlang
nodes. `/attach` sees only named nodes with a compatible cookie; start an
application with `--sname` or `--name`.

### A fork is rejected as unfinished

The entry or sequence number you chose is inside a turn whose tool calls have
no finished result yet. Cut after a completed turn instead:

```sh
lmx fork SESSION --at-turn N
```

`--unsafe` is for recovery work: it can produce a history a provider refuses
to continue.

### Resume uses an unexpected model or tool set

A resumed session takes its model and tools from its transcript, and an
ambient `LMX_MODEL` does not override them. Pass `--model` to switch the
model, or `--elixir` to replace the built-in tools. Hooks, provider
credentials, the base URL and the execution environment come from the current
host, not the transcript; see [Resume
precedence](configuration.md#resume-precedence) when you move a transcript
between machines.

## Crashes, logs and closed terminals

### Where log lines go

By default, `lmx` writes no log lines into the terminal UI or into
`lmx run`'s output. They go to `logs/lmx.log` in the state directory, usually
`~/.lmx/logs/lmx.log` (rotated at 1 MB, three old files kept), at the `error`
level. To see more, raise the level; the lines are then also printed on
standard error:

```sh
LMX_LOG_LEVEL=debug lmx run "reproduce the failure" 2> debug.log
```

Standard output still holds only the answer. The terminal UI keeps the lines
off its screen: while it is open they go only to the log file, unless you
redirected standard error when you started it
(`LMX_LOG_LEVEL=debug lmx 2> lmx-debug.log`), which then gets them too
(except on Windows, where the log file is the only place while the screen is
open). Read the log file, or redirect standard error, to watch them while it
runs. `lmx explain` reports the log file as `diagnostics.log_file`; with
`--config none` and no `LMX_HOME` there is none. At `warning` and below, a
failed request's log report can include the provider's response headers,
cookies among them, so read a log before you share it.

### lmx crashed

If the runtime itself crashes, the installed `lmx` (and every `mix lmx`
command from a source checkout) writes `erl_crash.dump` to `~/.lmx/crash/`
(`crash/` under `LMX_HOME` when that is set) rather than into your project.
A dump holds whatever the runtime held, provider keys and transcript text
included: never attach one to a public issue. Describe what you were doing,
attach the relevant lines of `~/.lmx/logs/lmx.log` instead, and then delete
the dump. `ERL_CRASH_DUMP` chooses another place for it.

The terminal may be left garbled; see [above](#the-terminal-is-garbled-after-lmx-was-killed).

### lmx was closed or interrupted in the middle of a turn

In the installed `lmx`, Ctrl-C (in `lmx run`), closing the terminal, and
`kill PID` all cancel the running turn: the cancellation is recorded in the
transcript, and the command the agent was running is stopped with its whole
process group. It exits 130 for Ctrl-C, 129 for a closed terminal and 143 for
SIGTERM. A launcher killed outright (`kill -9`, `timeout -s KILL`) takes the
same path within about a second; your shell then reports the launcher's own
status (137 for `kill -9`). From a source checkout, Mix owns the signals:
Ctrl-C in `mix lmx run` opens the BEAM's BREAK menu, and closing the terminal
ends the VM at once, while `kill PID` on `mix lmx` running the terminal UI
leaves the screen, prints the resume hint and exits 0. `lmx -c` (or
`lmx --resume SESSION`) picks the conversation up again, and `/undo` takes
back what the stopped turn changed. If the runtime itself stopped in the
middle of a command (a source run's closed terminal, say), `/undo` names that
command as not recorded.
