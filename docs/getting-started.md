# First session with lmx

`lmx` is a coding agent for your terminal. This guide installs it, connects a
model, runs a first prompt, and shows what runs without asking. You need a
model: an API key from a provider, who bills your requests, or a model running
on your machine in Ollama.

> **Requirements**
>
> - **The `lmx` binary:** macOS on Apple Silicon or Intel (each release's
>   notes give the oldest macOS it supports), or x86-64 Linux with glibc 2.34
>   or newer and its `libgcc_s` (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+,
>   Rocky, Alma, openSUSE, Amazon Linux 2023), `ca-certificates` and `awk`.
>   The installer needs `curl` and Python 3.8 or newer. Windows x86-64 is
>   experimental.
> - **A source checkout instead:** git and [mise](https://mise.jdx.dev/), on
>   macOS or Linux, x86-64 or arm64 (Linux arm64 has no binary yet).
> - **A model:** one provider's API key, or Ollama serving a model that can
>   call tools with a context window of at least 32k tokens.
> - **Network:** `lmx` connects to providers directly. It does not use
>   `HTTP_PROXY` or `HTTPS_PROXY`, so a network that only lets traffic out
>   through a proxy will not work. It trusts the operating system's
>   certificate store: add a company CA there, not to `SSL_CERT_FILE`.

## Install lmx

### The installed binary

On macOS and Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
```

`install.sh` downloads `install.py`, `SHA256SUMS` and `SHA256SUMS.sig` from the
latest release. `install.py` checks the signature against the release key
pinned in it, checks every download against the signed checksums, and only
then installs; nothing from the archive runs while it installs. The
installation belongs to your user: the launcher goes to `~/.local/bin/lmx`
and the runtime to `~/.local/share/lmx`, which only you can read. The
installer refuses to run as root unless you pass `--prefix`, because an
installation made with `sudo` could then be run and updated only by root.

The installer ends by naming the launcher and asking you to put its directory
on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"   # add this line to your shell profile
lmx --version
```

Pass options after `sh -s --`: `--prefix DIR` installs under `DIR`,
`--release X.Y.Z` picks a release, and `--replace` installs over a
`PREFIX/bin/lmx` the installer did not write. To upgrade later, run
`lmx update`, or run the installer again: it upgrades its own installation
without `--replace`. The previous version stays on disk for rollback.

Platform notes:

- **macOS:** the builds are not signed by Apple. Install them with `install.sh`
  or `install.py`, not by unpacking a downloaded archive in Finder: an archive
  unpacked that way is quarantined, and Gatekeeper then blocks the runtime's
  programs.
- **Linux:** the installer refuses a system with glibc older than 2.34, or a
  musl distribution such as Alpine, and points to the source checkout below.
  Without `ca-certificates`, it warns that `lmx` cannot reach HTTPS
  providers. The archive's start scripts also use `awk`, which some slim
  container images leave out: without it `lmx` still starts, but prints
  `awk: command not found` each time.
- **Linux arm64:** there is no binary yet; use the source checkout.
- **Windows x86-64 (experimental):** download `lmx_windows.tar.gz` from the
  [latest release](https://github.com/houllette/lemieux/releases/latest),
  unpack it into a new directory, and run `bin\lmx.cmd` there (from Git Bash,
  `bin/lmx` works too); [Windows (experimental)](releases.md#windows-experimental)
  has the steps, including checking the download. `lmx` needs
  [Git for Windows](https://gitforwindows.org/): its Git Bash runs the agent's
  commands, and WSL's `bash.exe` is never used. Under WSL2, run the installer
  inside WSL to get the Linux build instead.

An `lmx` installed with `install.sh` or `install.py` checks for a new release
when the terminal UI starts, after `/new` and `/resume`, and hourly while it
is open. It installs an update only after its manifest's signature verifies
against the public key built into `lmx`; a compatible update may load into
the running terminal UI, otherwise it applies at the next start.
`lmx update` installs one from a terminal, and `lmx update --check` only
says whether one is available. `LMX_AUTO_UPDATE=0` keeps the notices but
installs only when you run `lmx update` or `/update`, and
`LMX_CHECK_UPDATES=0` turns the automatic checks off; both still check.
`lmx run` never checks. An archive you unpacked
yourself, and the Windows build, only say when a release is out: update them
by downloading the new archive.

The first download trusts HTTPS and GitHub. To check a release before you run
anything, follow [Verify a download](releases.md#verify-a-download).
[Install an archive you downloaded](releases.md#install-an-archive-you-downloaded)
covers installing one you verified.

### From a source checkout

Install [mise](https://mise.jdx.dev/), then, in a real terminal:

```sh
git clone https://github.com/houllette/lemieux.git
cd lemieux
mise install                 # the Erlang and Elixir versions in .tool-versions
mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, with the same
arguments the binary takes:

```sh
mise exec -- mix lmx                          # the terminal UI
mise exec -- mix lmx run "Summarize this repository"
mise exec -- mix lmx help models
mise exec -- mix lmx log SESSION
```

Wherever these guides say `lmx`, write `mise exec -- mix lmx` and add
`-C /path/to/your/project` to work on another repository. asdf reads the same
`.tool-versions`: run `asdf install` and use its `mix`.

The first run compiles Lemieux and its dependencies: about a minute on a
recent machine, with warnings from dependencies that you can ignore. Later
starts are quick. Mix prints compile progress on standard output, so run
`mise exec -- mix compile` once before redirecting `mix lmx run …` into a file
or a pipe.

To type `lmx` in any directory, add a shell function to your profile; this
one assumes the checkout is at `~/src/lemieux`:

```sh
lmx() { mise -C ~/src/lemieux exec -- mix lmx -C "$PWD" "$@"; }
```

A source run reads the checkout's own `.env` file, and a variable already set
in your shell wins over it. Copy `.env.example` to `.env` to start one: every
line in it is commented out, so uncomment only what you fill in, because an
empty key line switches off a key saved in `~/.lmx/config.json`. The
installed binary reads no `.env` at all.

On Linux, `mise install` downloads a prebuilt Erlang on Ubuntu. Elsewhere it
compiles Erlang, which needs a compiler and the OpenSSL and ncurses headers.
Without the OpenSSL headers the build seems to succeed, and `mix deps.get`
then fails with `module :crypto is not available`.

- **Debian:** `MISE_ERLANG_PRECOMPILED_OS=ubuntu-22.04 mise install` uses
  Ubuntu's prebuilt Erlang, with no compiler needed. To compile instead:
  `sudo apt-get install build-essential autoconf m4 libncurses-dev libssl-dev`.
- **Fedora, RHEL, Rocky, Alma:** the Ubuntu build does not work there. Install
  `sudo dnf install gcc gcc-c++ make autoconf ncurses-devel openssl-devel perl`,
  then `mise install`.

To build your own `lmx` binary from the checkout, see
[Build and inspect locally](releases.md#build-and-inspect-locally). You do not
need one to try `lmx`.

## Connect a model

### With an API key

Set one provider's key in your shell. You do not have to name a model: `lmx`
starts on the recommended model of the first provider in this list whose key
it finds.

| Provider | Key |
| --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google Gemini | `GOOGLE_API_KEY` |
| xAI | `XAI_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Z.AI Coding Plan | `ZAI_API_KEY` |

`lmx help models` prints the same list with the model each key starts on.
These are model identifiers, not a promise of access for your account.

```sh
export ANTHROPIC_API_KEY='your-key'
cd /path/to/your/project
lmx
```

When nothing names a model (no `--model`, `LMX_MODEL` or `"model"` in
`~/.lmx/config.json`), `lmx` starts on the first of these that works:

1. the model you last named with one of those when you started the terminal
   UI, if it can still be reached (a model you switch to with `/model` or
   `/provider` in a running session, or use with `lmx run`, is not
   remembered);
2. the recommended model of the first provider above whose key is set, in the
   environment or saved in `~/.lmx/config.json`;
3. a model your local Ollama serves that can call tools, with a notice saying
   so;
4. nothing yet: the terminal UI asks you to choose a provider.

`--model PROVIDER:MODEL` or `LMX_MODEL` names any other model. In the
terminal UI, `/provider` switches provider and `/model` picks a model within
it. A key variable set to an empty value counts as no key, and also switches
off a key saved in the config file.
[Which model lmx starts on](cli.md#which-model-lmx-starts-on) has the details.

With no key and no local model, the terminal UI opens **Choose a model
provider**, with no provider picked for you. Pick one and paste its API key:
`lmx` saves the key and that provider's model in `~/.lmx/config.json`, in
plain text that only you can read. Esc closes the panel without saving
anything, so you can look around first; it opens again at the next start. To
use an environment variable instead, quit, set it and start `lmx` again:
`/provider` switches provider but saves no key. A prompt sent in the meantime
gets this answer:

```text
no provider key was found · start again and paste one when asked, or set one such as ANTHROPIC_API_KEY or OPENAI_API_KEY first; or run a model on this machine with Ollama: /provider ollama
```

`lmx run` cannot ask, so without a usable key it exits with status 3 and a
sentence saying what to set.

Keep keys in your environment or in `~/.lmx/config.json`. The installed `lmx`
never reads a `.env` file from the directory it starts in, so a repository you
open cannot supply a key, or change where your key is sent.

### Use a local model

`lmx` runs models on your machine through [Ollama](https://ollama.com), with
no key and no account. It needs a model that can call tools, served with a
long enough context window: unless told otherwise, Ollama serves 4,096 tokens
on a machine with less than about 23 GiB of GPU memory, and it silently drops
the start of a longer conversation, your task first.

1. Start (or restart) Ollama with a window of 65,536 tokens, or 32,768 at
   the least:

   ```sh
   OLLAMA_CONTEXT_LENGTH=65536 ollama serve
   ```

   The desktop app has a Context length setting instead; for a Linux service
   or a single model, see [the recipe](providers.md#the-recipe).
2. Pull a model that can call tools: `ollama pull NAME`.
   [ollama.com/search?c=tools](https://ollama.com/search?c=tools) lists them.
3. Start `lmx` with no API key set. It picks the local model and says so in a
   notice. With a key set, name it: `lmx --model ollama:NAME`, or
   `/provider ollama` in the terminal UI, after which `/model` lists the other
   local models that can call tools.
4. Once `lmx` has sent its first request, check the CONTEXT column of
   `ollama ps`: that is the window the model really has.

A local model can take minutes to start answering a long request; `lmx`
waits up to 15 minutes for the first token.
[Use a local model](providers.md#use-a-local-model) is the reference: how
`lmx` reads the served window, what its notices mean, the limits it applies
to local models, and a daemon on another machine.

## Your terminal

Run `lmx` in a real terminal window, not through a pipe. A few settings make
it work better:

- **macOS: let Option send Alt.** Shortcuts such as Alt-1 to Alt-9 (select a
  queued message), Alt-E, Alt-U, Alt-N and Alt-Z need it; out of the box,
  macOS terminals type special characters instead. Terminal.app: Settings >
  Profiles > Keyboard > "Use Option as Meta key". iTerm2: Settings > Profiles >
  Keys > Left Option key: Esc+. VS Code: `"terminal.integrated.macOptionIsMeta": true`.
  On a non-US layout, keep the right Option key as Normal so you can still
  type `@` and `{`. Under tmux, the outer terminal's setting is the one that
  counts.
- **Scrolling.** Page Up and Page Down scroll the conversation. In
  Terminal.app they scroll Terminal's own buffer instead: use Shift-Page Up
  and Shift-Page Down (Shift-Fn-Up and Shift-Fn-Down on a laptop), or the
  mouse wheel.
- **Selecting text.** `lmx` captures the mouse so the wheel scrolls.
  Shift-drag still selects (Option-drag in iTerm2, Fn-drag in Terminal.app),
  and `--no-mouse` gives the mouse back to the terminal.
- **Light backgrounds.** When no theme is chosen, `lmx` asks the terminal for
  its background and starts in its light theme on a pale one. `/theme light`,
  `/theme dark` or `/theme mono` changes it for the sitting, and
  `"theme": "light"` in `~/.lmx/config.json` makes it stick. `NO_COLOR=1`
  turns colour off, and a startup notice says so when it is set, since a
  launcher or an agent's shell often sets it without your meaning to.
- **Colours.** `lmx` draws 256 colours unless the terminal says it has 24-bit
  colour. If yours has it but does not say so, `export COLORTERM=truecolor`.
- **Multiplexers.** tmux works. GNU screen 4 (macOS's `/usr/bin/screen`)
  passes no bracketed paste, so a pasted block arrives as typed lines: the
  first is sent as a prompt and the rest as messages sent while the model
  works ([steers](#ask-one-useful-question)).

## Understand what can run

Out of the box `lmx` does not ask before running tools, and the startup
banner says so: "full auto".

- `read`, `write` and `edit` refuse paths outside the session's working
  directory (through `..`, absolute paths or symbolic links). Confinement is
  by path, so a hard link inside the tree to a file elsewhere is written
  through.
- `write` will not replace a file the session has not read, or one that has
  changed since.
- **`bash` runs as your operating-system user and is not sandboxed.** It
  gets the environment you started `lmx` in, less variables whose names
  contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`. The check reads
  names only, so a password inside `DATABASE_URL` still passes.
- After a turn that edited files, `lmx` runs your project's own check (the
  post-edit check), such as `make test`; it follows the same permission
  policy as the agent's commands.
- A repository's `.mcp.json` servers wait until you trust that file: the
  terminal UI asks, showing what each server would run. A repository's
  instructions and skills are read as model context, never as code, and its
  `.claude/settings.json` hooks never run on their own. Extensions and
  command hooks you load yourself are trusted code.
- `/undo` takes back what the last turn changed that was recorded: everything
  `write`, `edit` and `apply_patch` changed and, when the working directory
  is a git repository, what commands and the post-edit check changed in
  tracked files and in untracked files up to 1 MB. It names what it could not
  put back (ignored files such as `.env` that a command changed, files a
  command changed that git keeps through a filter such as Git LFS, files
  outside the working directory, commands run outside a git repository, MCP
  tool calls), and `/redo` takes an undo back. Outside a git repository, a
  startup notice says that `/undo` covers file-tool edits only. Try `lmx` in
  a git repository first;
  [Taking changes back](everyday.md#taking-changes-back) has the full list.

To be asked first, start with `--permission-mode ask`, or with
`--permission-mode accept_edits`, which lets file edits through and asks
before commands. `--sandbox` runs the agent's commands inside macOS Seatbelt
or Linux bubblewrap (install `bubblewrap` first): they write only to the
working directory, temporary directories and tool caches, reach no network
beyond loopback, and cannot see credential locations such as `~/.ssh`,
`~/.aws` and `~/.git-credentials`, which the file tools refuse too
(`lmx help sandbox` lists them). The
[trust model](../SECURITY.md#what-lmx-trusts-by-default) lists exactly what is
guarded and what is not.

Limits are optional. `--max-requests 20` stops the session after 20 model
requests (retries and compaction count) and shows `req 3/20` on the status
line. `--max-turns` bounds one prompt. `--max-cost-usd 2` stops before a
request that could take the session past $2, and stops outright when the
model's price is unknown. All three apply to the session's own work only.
`lmx` can also hand read-only questions to up to three helper sessions
at once, the repository scout, and their spending does not count toward
`--max-requests` or `--max-cost-usd`: together they spend at most $9 per
session (or 2,880 requests where a price is unknown). `--no-delegate` turns
the scout off when one number must bound everything. See
[session limits](cli.md#session-limits).

## Ask one useful question

Start with: `Read README.md and explain the public entry points. Do not change files.`

Enter submits. Shift+Enter inserts a newline where the terminal can tell it
apart; Ctrl-J, or a line ending in `\`, always does. Type `/help` for commands
and keys, `/model` to pick a model, and `/context` for context use.
`/cancel` (or Ctrl-C) stops a turn, `/undo` takes back what the last turn
changed (a command you stopped included), `/redo` takes an undo back, and
`/quit` leaves. Text you send while the model is working steers its next
request. The header shows the working directory, the session's name and the
model; the status line shows context use, cost and, with a request cap,
`req N/M`. [Everyday use](everyday.md) walks through the rest.

A one-shot task:

```sh
lmx run "Summarize this repository without changing files" > summary.md
```

Only the final answer goes to standard output; progress, usage and errors go
to standard error. `lmx run` loads the same workspace instructions and skills
as the terminal UI (`--bare` leaves them out), reads the prompt from standard
input when you pipe one, and exits with a status that says what happened
(`--output-format json` for scripts). The
[CLI reference](cli.md#one-shot-command) explains the modes.

A prompt on the command line needs `run`: `lmx "fix the bug"` is not a
command, so `lmx` says so and prints the `lmx run` line that would have asked
it, beside the plain `lmx` that opens the terminal UI.

## Save settings and resume

The first start creates `~/.lmx/config.json`, readable only by you. Edit it to
pin a model or save limits; keys can stay in your environment:

```json
{"version": 1, "model": "anthropic:claude-sonnet-5", "max_requests": 20}
```

Flags win over environment variables, which win over the file. When you resume
a session, limits you set now replace the old ones, and requests already made
still count. Automatic compaction is on; `"auto_compaction": false` turns it
off, and `/compact` still works.

When you leave the terminal UI, `lmx` prints how to come back:
``lmx: session NAME is saved · `lmx -c` resumes it``.

```sh
lmx -c                      # resume the newest session in this directory
lmx --resume SESSION        # or a particular one, by id or name
lmx log SESSION             # print it, offline
lmx fork SESSION --at-turn 2
lmx explain                 # what a new session would start with
```

`/resume` inside the terminal UI lists this directory's sessions, most
recently active first. `lmx explain` prints, as JSON, what a new session would
start with: the model and what chose it, which keys it can see (never their
values), versions, tools and limits. It calls no model, though it may ask a
local Ollama which models it serves, and extensions you selected still run
their initialization. Sessions are stored in `~/.lmx/sessions`, and `log` and
`fork` work offline. Log lines go to `~/.lmx/logs/lmx.log`, not to the
terminal. If the runtime itself ever crashes, its crash dump goes to
`~/.lmx/crash`; a dump can hold your keys, so never attach one to an issue.

## Next steps

Continue with [Everyday use](everyday.md) for steering, approvals, undo and
scripting. Use [Configuration](configuration.md) to save your defaults, or
[Customizing Lemieux](customization.md) to add instructions, tools or
behaviour. [Troubleshooting](troubleshooting.md) covers diagnosis and
recovery.
