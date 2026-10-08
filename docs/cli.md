# CLI and terminal UI

`lmx` is an open-source terminal coding agent built on the Lemieux runtime.
This page is the reference for its commands, keys, options, environment
variables and exit statuses. [Everyday use](everyday.md) is the walk-through,
[First session with lmx](getting-started.md) gets it installed, and
[Configuration](configuration.md) covers `~/.lmx/config.json`. The
[glossary](index.md#words-you-will-meet) defines the terms these pages use,
such as host, session, transcript, harness, checkpoint and scout.

Help is built in:

```sh
lmx --help            # commands, common options, exit statuses, links
lmx help TOPIC        # one topic in full
lmx mcp --help        # a command's own topic, where it has one
```

The topics are `config`, `models`, `permissions`, `sandbox`, `mcp`,
`plugins`, `skills`, `extensions`, `sessions`, `environment`, `options` (the flags
`lmx --help` leaves out, apart from the MCP OAuth flags in `mcp` and the
builder flags in `learning`), `learning` (the experimental
harness-learning commands) and `desktop` (`lmx desktop`).

## Commands

| Command | What it does |
| --- | --- |
| `lmx`, `lmx tui` | Open the full-screen [terminal UI](#terminal-ui) |
| `lmx run PROMPT` | Answer one prompt and exit, for scripts and CI ([one-shot command](#one-shot-command)) |
| `lmx log SESSION` | Print a stored conversation ([transcripts](#transcripts-resume-and-fork)) |
| `lmx fork SESSION [CUT]` | Copy a conversation so you can branch from it |
| `lmx request SESSION ID` | Print the canonical request behind one recorded model call |
| `lmx explain` | Print, as JSON, what a new session would start with, without calling a model |
| `lmx mcp list\|trust\|untrust\|import` | Manage MCP servers ([plugins, extensions and MCP](#plugins-extensions-and-mcp-servers)) |
| `lmx plugin install\|list\|remove` | Save or forget Claude Code-compatible plugins |
| `lmx extension new\|list` | Write or list your own Elixir extensions |
| `lmx skills` | List the Agent Skills a session finds, where each came from, and whether it is enabled |
| `lmx desktop install\|uninstall\|status` | On Linux, add `lmx` to the desktop's application launcher, or remove it ([Desktop launchers and Omarchy](desktop.md)) |
| `lmx update [--check]` | Install a newer verified release from a terminal, or say whether one is available ([Updates](releases.md#updates-from-the-tui)) |
| `lmx help [TOPIC]` | Print the help, or one topic |
| `lmx feedback`, `lmx corpus`, `lmx harness` | Experimental [harness-learning commands](#harness-learning-and-feedback-commands) |
| `lmx --version` | Print the version |

`lmx explain` prints a sanitized JSON report: the model and what chose it
(`model_source`), the route, which credentials are present (never their
values), tools, limits, the defaults that were applied and the log file. It
makes no model request, though an extension's start-up code or a gateway
lookup can still run. `--explain-against FILE` compares with a saved report,
and `--no-user-extensions` leaves your own extensions out. It exits 1 after
the report when two tools share a name, because a session would refuse to
start with them; see [Troubleshooting](troubleshooting.md).

`lmx skills` lists the Agent Skills and legacy commands a session started
in this directory finds: for each, where it came from (bundled, Omarchy, a
personal directory, the repository, `--skill-dir` or a plugin), whether it is
enabled, disabled in the config or invocable only one way, its path and real
path, and the copies of its name it hid. It also says whether Omarchy's
skills are read and where it looked, and prints the notices about skills.
It takes `-C DIR`, `--config`, `--skill-dir`, `--plugin-dir`,
`--marketplace` and `--plugin` as `lmx run` does, and `--json` for scripts.
[Agent Skills](configuration.md#agent-skills-and-legacy-commands) has the
order skills are read in and the `"skills"` settings.

The terminal UI and `lmx run` start a session the same way: the same model
choice, workspace, tools and defaults. [Configuration](configuration.md#defaults-lmx-turns-on-and-the-keys-that-change-them)
lists the defaults and the settings that change them, and the [trust
model](../SECURITY.md#what-lmx-trusts-by-default) says what runs without
asking.

### From a source checkout

Every command on this page also runs from a clone of the repository, through
Mix:

```sh
git clone https://github.com/houllette/lemieux
cd lemieux
mise install
mise exec -- mix deps.get
mise exec -- mix lmx                                  # the terminal UI
mise exec -- mix lmx run "Summarize this repository"
mise exec -- mix lmx -C ../my-project                 # work in another repository
mise exec -- mix lmx help models
```

`mix lmx` takes exactly the installed binary's arguments, and the hints it
prints say `mix lmx` instead of `lmx`. `mix lmx.tui` still works and is the
same as `mix lmx tui`.

The bundled [System One compaction](configuration.md#system-one-compaction) extension is
part of the release host in `dist/lmx`, a Mix project with its own
dependencies. To include it, fetch them once and run from there; the agent
still works in the repository root, not in `dist/lmx`:

```sh
cd dist/lmx
mise exec -- mix deps.get
mise exec -- mix lmx
```

To use the checkout from any directory, define a shell function (change the
path to your clone):

```sh
lmx() { mise -C ~/src/lemieux exec -- mix lmx -C "$PWD" "$@"; }
```

Mix prints compile progress on standard output, so run
`mise exec -- mix compile` once before you redirect `mix lmx run …` into a
file or a pipe. A source run from the repository root also reads the
checkout's own `.env`; a run from `dist/lmx` and the installed `lmx` read
none (see [Environment variables](#environment-variables)).

## Terminal UI

```sh
lmx [OPTIONS]
lmx tui [OPTIONS]
lmx --prompt TEXT [OPTIONS]
```

Bare `lmx` opens the full-screen terminal UI. You type a prompt; the agent
works through its tools on screen; you can steer it, queue the next message,
answer its questions, approve calls and take its changes back. The installed
binary is a native OTP release, so the screen's native library ships inside
it. A model specification that does not parse, or names a provider `lmx` does
not know, stops it before the screen opens, with `lmx run`'s sentence and
status 2.

**When it starts.** A notice box at the top shows the startup banner, which
states the permission mode and the sandbox, by default `full auto: tools run
without asking · commands are not sandboxed`, followed by any workspace or
configuration notices and the MCP servers that connected. The box closes ten
seconds after its newest line, or at once on Esc. The startup never waits: MCP
servers connect in the background (`connecting NAME…` on the status line,
details in `/mcp`), and you can type while the session starts; Enter queues
the draft until it is ready. If the session cannot start, `/model`,
`/provider` and `/quit` still work, and choosing a model or provider starts
it again. If the session process crashes, a row says so and Enter on an empty
line resumes it.

**With a first prompt.** `lmx --prompt TEXT` opens the terminal UI and sends
`TEXT` as its first message, shown as if you had typed it. It waits in the
queue while the session starts, and is sent once the session is up and
these questions are answered: the provider panel below, and whether to
start the repository's MCP servers. With `-c` or `--resume`, it is that
session's next message. Write `--prompt=TEXT` when `TEXT` starts with `-`.
An empty `TEXT` is refused. `lmx run` does not take `--prompt`; its prompt
is its argument. Launchers use it to start an interactive session with a
task ([Desktop launchers and Omarchy](desktop.md#starting-lmx-from-a-launcher-or-an-agent-selector)).

**With no usable key**, a *Choose a model provider* panel opens. Pick a
provider and paste its API key; it is saved to `~/.lmx/config.json` (mode
`0600`) with that provider's model. A provider whose key is already set needs
nothing pasted, and when a local Ollama serves a model that can call tools, a
last row offers it with no key. No provider is selected unless you named the
model or resumed a session: then its provider is selected, its row carries
your model, the panel says which model has no key, and a key pasted there is
saved alone, leaving the session and your configured model as they were.
Esc closes the panel with `no key
saved · set one in your environment, or paste it here at the next start`,
followed by the `/provider` switches that work now, such as
`/provider ollama`. The panel opens again the next time `lmx` starts.
Meanwhile `/provider ollama` switches to a model the local Ollama serves,
asking Ollama again when it found none as `lmx` started (`/model NAME` then
picks another it serves). `/provider` saves no key.
[Which model lmx starts on](#which-model-lmx-starts-on) says when the panel
appears.

**When a repository's `.mcp.json` is not yet trusted**, a panel lists each
server's command or URL and the variables it reads, and asks before anything
starts; see [Repository MCP servers wait for
trust](configuration.md#repository-mcp-servers-wait-for-trust).

**On screen.** The header reads `lemieux (vX) · DIR · NAME · PROVIDER · MODEL
· effort E`, where DIR is the working directory (`~` for your home,
shortened when it is long) and NAME is the session's name. The terminal tab
or window title becomes `lmx | NAME | DIR`. The status line under the input
box shows the context use, the spend, the permission mode when permissions
are on, and `req N/M` when a request cap is set. A live row at the foot of
the transcript says what the turn is doing right now: `thinking (40s)`,
`running bash (2m)`, `waiting for your approval of bash`.

**When it ends.** On a clean exit, `lmx` prints where the conversation went:
``lmx: session NAME is saved · `lmx -c` resumes it`` (with `-C DIR` when the
session worked in another directory).

Besides the conversation, the terminal UI gives you:

- completion for slash commands, providers, models, effort levels, sessions,
  tool names and BEAM nodes. A bare `/` lists `lmx`'s own commands; when you
  have skills from elsewhere, the menu has a tab per place they came from
  (Project, Personal, Claude, Codex, Agents, System, Plugins, `--skill-dir`),
  switched with Shift-Tab or a click, and typing a skill's name jumps to its
  tab. Lists of names are alphabetical; `/model` puts
  preferred and recent models first, then the rest by release date, with
  deprecated models marked near the end;
- the model's plan (its `todo` tool) above the input while a task is open;
- edits, writes and patches drawn as numbered diffs, and the full output of
  any recent tool call a Ctrl-O away;
- a fuzzy `@` file picker that skips ignored files, and images pasted from
  the clipboard with Ctrl-V ([Attaching files](#attaching-files));
- input history shared across sessions (`~/.lmx/history.jsonl`, private, the
  last 1,000 lines), searched with Ctrl-R;
- a desktop notification (OSC 9 and the bell) when a long turn ends or a turn
  waits for you; Alt-N turns it off until you quit, `"notifications": false`
  for good;
- a follow-up hint in the empty input box after a turn, taken with Tab. It is
  guessed from what the turn's tools did, never by a model call;
- the repository's instructions, skills and legacy slash commands, and the
  plugins you selected ([Workspace discovery](configuration.md#workspace-discovery)).
  A user-invocable skill is another slash command (`/NAME [ARGUMENTS]`, or
  `/PLUGIN:NAME` for a plugin's), on the completion menu's tab for where it
  came from; the bundled `/create-extension` and `/evaluate-extension`
  skills sit with `lmx`'s own commands and help you write and check an
  extension;
- local models: when an Ollama daemon is running, its models that can call
  tools appear under `/provider ollama` and `/model`. `/provider ollama`
  switches to the Ollama model you pinned or used recently, else to the one
  `lmx` would start on by itself. `OLLAMA_API_KEY` adds Ollama Cloud's
  catalog;
- with Ixway and direct API keys both configured, `/provider` offers both
  routes and `/model` shows models for the selected provider. Ixway models
  open in the Ixway tab, with qualified provider routes in separate tabs.

**Updates.** `lmx update` installs a newer verified release from a terminal,
without a session, a key or a readable config file; `lmx update --check` only
reports ([Updates](releases.md#updates-from-the-tui)). On macOS and Linux,
the installed binary also checks the project's GitHub releases when the
terminal UI opens, after `/new` and `/resume`, and
hourly while it is open. It installs an update only after the release's
signed manifest verifies against the Ed25519 public key built into the
binary; a release whose signature is missing or does not verify is reported
in the notice box and never installed. An offline or failed check stays
silent. A compatible update may load into the running screen; otherwise it
applies at the next start, and the first start after it links that
release's changelog. `LMX_CHECK_UPDATES=0` turns the automatic checks off;
`/update` still checks. `LMX_AUTO_UPDATE=0` keeps the notices and installs
only when you run `/update`. Selecting your own extensions also turns
automatic installation off; `/update` still installs, and the update applies
at the next start. An `lmx` unpacked by hand and the experimental Windows
build show notices only. A source checkout checks nothing on its own:
`/update` fast-forwards a clean checkout from its upstream, then says to run
`mix deps.get` and restart `mix lmx`. `lmx run` and embedded hosts never
check. See [Updates from the TUI](releases.md#updates-from-the-tui).

### Keys

| Key | What it does |
| --- | --- |
| Enter | Send the input, or take the highlighted suggestion. A suggestion that needs an argument opens its next menu. While the agent works, Enter sends a [steer](#steering-and-the-queue) |
| Tab | Fill the highlighted suggestion; in an empty box, take the follow-up hint; while the agent works, queue the draft |
| Shift-Enter | New line, where the terminal reports Shift with Enter |
| Ctrl-J, or `\` at the end of a line then Enter | New line, in any terminal |
| Up / Down | Move through suggestions or the lines of a draft; Up at the first line browses history, Down on the current draft moves to its end |
| Alt-Up / Alt-Down | Browse input history |
| Ctrl-R | Search input history across sessions; Enter or Tab takes an entry, Esc restores the draft |
| Ctrl-G | Edit the draft in `$VISUAL` or `$EDITOR` (`vi` when neither is set); not on native Windows yet |
| Ctrl-V | Attach the image on the clipboard as an `@path` reference |
| Ctrl-O | Page through the full output of recent tool calls (less-style keys, ←/→ between outputs, q or Esc to close) |
| Page Up / Page Down | Scroll the transcript a page |
| Shift-Up / Shift-Down | Scroll the transcript three rows |
| Esc | Clear the input, the selection and the completion menu, and close the notice box |
| Ctrl-C | Cancel the running turn; when idle, press it twice to quit |
| Shift-Tab | Cycle the permission mode (ask → accept edits → auto → read only; never full auto) when permissions are on; when they are off it says how to turn them on. In the Ixway model picker it cycles through Ixway and qualified route tabs, and in the slash menu through the tabs for where skills came from |
| Alt-1 to Alt-9 | Select a queued message |
| Alt-E / Alt-U | Revise / discard the selected queued message |
| Alt-Z | Take back the steer waiting for the next model request, as `/unsteer` does |
| Alt-N | Turn desktop notifications off or on until you quit |
| `a` or `aN` on an approval card | Allow the call and remember the card's suggested rule or mode |
| Enter on an empty line after a crash | Resume the crashed session |

`/help` lists the same keys. Other editing keys (cursor and word motion,
deletion, selection with Shift, paste) belong to the input box. Among them,
Ctrl-U deletes back to the start of the line, and is what most macOS
terminals send for Cmd-Backspace; Ctrl-W and Alt-Backspace (Option-Backspace)
delete a word; Ctrl-Z undoes. Every binding
above can be changed with `"keys"` in `~/.lmx/config.json`; [Rebinding
keys](terminal-ui.md#rebinding-keys) lists the action names.

**On macOS, let Option send Alt.** Alt-1 to Alt-9, Alt-E, Alt-U, Alt-Z and
Alt-N need the Option key to act as Alt (Meta). Out of the box, macOS
terminals type characters instead: Option-1 types `¡`, and Option-E, U and N
are dead keys. Turn it on in:

- Terminal.app: Settings > Profiles > Keyboard > *Use Option as Meta key*;
- iTerm2: Settings > Profiles > Keys > *Left Option key*: Esc+;
- VS Code: `"terminal.integrated.macOptionIsMeta": true`.

On a non-US layout, keep the right Option key as Normal so you can still type
`@` and `{` (iTerm2 sets the two keys separately). Under tmux, the outer
terminal's setting is the one that counts.

**Terminal.app keeps Page Up and Page Down** for its own scrollback. Use
Shift-Page Up / Shift-Page Down (Shift-Fn-Up / Shift-Fn-Down on a laptop) or
the mouse wheel to scroll the conversation. Terminal.app also sends
Shift-Up / Shift-Down as plain arrows, which browse history there.

### Steering and the queue

While a turn runs, typing in the input box shows `Enter steer · Tab queue`
below it.

- **Enter sends a steer.** It reaches the model with its next request; the
  steer box reads `queued for next model request · /unsteer takes it back`.
  Only one steer waits at a time. `/unsteer` or Alt-Z takes it back until the
  next request starts, and answers `steer revoked before the next model
  request`, `steer already sent`, `no steer is waiting` or `the session
  stopped before the steer was sent`. Cmd-Z does the
  same only in a terminal that reports the Command key (the kitty keyboard
  protocol); Terminal.app, iTerm2 and VS Code keep Cmd-Z for their own Undo.
  A steer whose turn stopped first is marked `turn stopped before delivery`.
- **Tab queues a message** (or a slash command such as `/compact`) to send
  after the turn: up to nine, sent in order, one after each successful turn.
  They appear as numbered previews above the input. Alt-1 to Alt-9 selects
  one, Alt-E returns it to the input box for revision, and Alt-U discards it.
  A cancelled turn keeps the queue; a full queue leaves the current draft
  alone.

### Mouse, selection and copying

The mouse is captured by default, so the wheel scrolls the transcript. Left
uncaptured, terminals turn the wheel into arrow keys, which the input box
reads as history.

- **Drag across the transcript** to select; the range highlights, follows its
  text as the transcript scrolls or streams, and is copied when you release
  (the status line shows how many characters). Dragging past the top or
  bottom edge scrolls and keeps selecting. A click or Esc clears it.
- **Click a link** to open it. An http(s) address opens in the browser. A
  local file that is text opens in a text editor; a file whose type can
  launch or run code (`.app`, `.command`, `.sh`, `.exe`, `.bat`, `.ps1`,
  `.jar`, …) is not opened, and the status row says so; anything else is
  shown in its folder.
- **Click the count on the lower rail** to return to the latest rows when you
  have scrolled back.

To get the terminal's own selection back, hold a modifier while dragging
(Shift in most terminals, Fn in Terminal.app, Option in iTerm2), or start with
`--no-mouse` (`"mouse": false` for good), which costs the wheel. `/copy`
copies the latest response either way, and Page Up, Page Down and
Shift-arrows scroll either way. Copying uses the system clipboard tool
(`pbcopy` on macOS, `wl-copy`, `xclip` or `xsel` on Linux) when there is
one, and the terminal's OSC 52 sequence otherwise: over SSH, on Windows, or
when no tool works.

### Slash commands

`/help` lists these, in this order, with the key bindings after them and
links to the docs, issues and questions at the end.

| Command | What it does |
| --- | --- |
| `/model [SPEC]` | Show or select a model within the current provider |
| `/provider [NAME]` | Show or select a provider; switching provider is how you reach another provider's models |
| `/effort [LEVEL]` | Show or select a reasoning effort the model supports |
| `/new` | Start a new session: fresh name, transcript and usage totals |
| `/resume [SESSION \| all]` | List this directory's sessions, most recently active first, or switch to one; `all` lists every directory's |
| `/compact` | Summarize the earlier conversation now |
| `/context` | Draw what is filling the context window |
| `/cancel` | Stop the running turn (Ctrl-C does the same) |
| `/unsteer` | Take back the steer waiting for the next model request |
| `/retry` | Send the request that failed again, keeping everything before it |
| `/undo [--force]` | Put back what the last turn changed and name what it could not; `--force` overwrites files changed since, and right after an `/undo` that left files alone puts those back |
| `/rewind N [--force]` | Undo the last N turns |
| `/redo [--force]` | Take back the last `/undo`; `--force` overwrites files changed since |
| `/diff` | Show the working tree's `git diff` (or `git status`), bounded |
| `!COMMAND` or `/shell COMMAND` | Run a command yourself; its output is shown and handed to the model with your next message |
| `/copy` | Copy the latest agent response |
| `/export [PATH]` | Write the transcript as Markdown (default under `~/.lmx/exports`) |
| `/init` | Ask the agent to draft an `AGENTS.md` for this repository |
| `/memory [--project] TEXT` | Append a line to your memory file, or the repository's |
| `/permissions [MODE]` | Show or switch the permission mode, and list, add or forget remembered rules |
| `/approve [CALL_ID \| all]` | Run a tool call waiting for approval; bare, the oldest one |
| `/deny [CALL_ID \| all] [REASON]` | Refuse a waiting tool call; the reason is what the model reads |
| `/verify [on \| off]` | Show or switch the check that runs after a turn that edited files |
| `/delegate [on \| off]` | Offer or withhold the [repository scout](#delegated-repository-investigation) for this session |
| `/tools [list]` | List local and MCP tools with their enabled or disabled status |
| `/tools enable NAME...` / `/tools disable NAME...` | Enable or disable one or more tools at once, while idle |
| `/mcp` | Open the MCP server panel; `/mcp list`, `add PATH`, `remove NAME` and `reconnect [NAME]` are the text forms |
| `/prompts` | List the prompts your MCP servers offer; each runs as `/mcp__SERVER__PROMPT [ARGS]` |
| `/name [TEXT]` | Show or change the session's label on screen, until you quit |
| `/color [COLOUR]` | Show or change the accent colour |
| `/theme [NAME]` | Show or switch the palette: `dark`, `light`, `mono` or one of yours |
| `/update` | Check for and apply an update of the installed release, or fast-forward a clean source checkout |
| `/doctor` | A readable report of the model and key, limits, MCP servers, permissions, checkpoints, sandbox and platform tools |
| `/help` | Show the commands and key bindings |
| `/quit` or `/exit` | Leave |
| `/reflect` | Review the session and suggest prompt, skill, extension or harness improvements (experimental) |
| `/reflect opportunities` | The same review, as records written to the feedback ledger |
| `/feedback [TEXT]` | Record what should have gone differently, anchored to a moment in this session |

With the Elixir extension (`--elixir`, or in an Elixir project) there are
three more: `/elixir` toggles the Elixir-only tool profile, `/attach [NODE]`
lists local named BEAM nodes or attaches evaluation to one, and `/detach`
returns evaluation to the session's own node.

**What `/undo` covers.** It puts back what `write`, `edit` and `apply_patch`
changed (a file over 10 MB is named instead) and, when the working directory
is a git repository, what commands and the post-edit check changed in
tracked files and in untracked files up to 1 MB. It names what it could not
put back: commands run outside a git repository, ignored files such as
`.env` that a command changed, tracked files stored through a filter driver
(Git LFS, git-crypt) that a command changed, MCP tool calls, commits and
branch switches. Files a command changes outside the repository it ran in
(your home directory, say) are neither put back nor named. A file changed
since the agent changed it is left alone and named. Where what commands
change cannot be recorded, the notice box says so at startup:
`/undo covers file-tool edits only here: not a git repository, so what
commands change is not recorded` (or `git was not found`, `the git
repository ignores this directory`, `the git repository's work tree is set
to another directory`). `/doctor` says the same in its checkpoints row.
[Taking changes back](everyday.md#taking-changes-back) has the full list.

**Busy turns.** Commands that change the model, provider, effort, tools,
session or MCP servers wait until the turn is idle. `/cancel` and `/unsteer`
work mid-turn, and so do `/name`, `/color` and `/theme`, which only change
what the screen draws.

**Approvals.** When a call is parked for approval (by the permissions
extension, a command hook that answers `ask`, or an embedding host), the
screen shows the call under an ` approve? ` input box. `y`, `yes` or `allow`
runs it; `n`, `no` or `deny`, with anything after the word as the reason,
refuses it, and the reason is what the model reads. When the permissions
extension parked it, the card also shows the mode, why it asked and numbered
"always allow" suggestions (a rule such as `Bash(npm test:*)`, or a mode):
`a` takes the first and `aN` the Nth, then runs the call. `/approve` and
`/deny` answer by call id when several wait. The screen waits as long as it
takes, and the call's own deadline is paused meanwhile. An `ask_user`
question opens a panel with suggestions, an Other answer and a review step.

**`/resume`** skips sessions that were opened and left without a prompt. A
session already open in another `lmx` cannot be resumed; the message names
that process and the lock file to delete if it is gone.

**`!COMMAND`** runs through the session's environment, so the credential
scrub, path confinement and any sandbox apply as they do to the agent's own
`bash`. Its output is bounded, shown, and carried once into your next
message, marked as something you ran.

**`/tools`** lists local and MCP tools while busy; enabling or disabling
waits for an idle session, takes exact names and applies all of them or
none. Tool changes are recorded and restored on resume.

**`/name`, `/color` and `/theme`** last until you quit and are not stored
with the session. `/name TEXT` relabels the session in the header and
the tab title; `--resume` and `lmx log` still take the id or the derived
name, and `/name default` gives the derived name back. `/color COLOUR`
recolours the rails, the input cursor and the highlighted completion (Tab
lists the names; `#rrggbb` works; `/color default` restores it). `/theme`
switches every other colour: `dark`, `light` for a pale background, or
`mono`, which draws no colour and keeps bold, dim and italic. `"theme"` in
`~/.lmx/config.json` chooses the palette the terminal UI starts in; with none,
`lmx` starts in `light` when the terminal reports a light background
([Themes](terminal-ui.md#light-and-dark-backgrounds)).

There is no `/refresh` in the list: typing `@` re-reads the files this
conversation attached and re-attaches any that changed, at most once every
ten seconds. Typed, `/refresh` still works. Every slash command is a
`Lemieux.Conversation.Command` module, and a host adds its own as [Adding a
slash command](terminal-ui.md#adding-a-slash-command) shows.

## Attaching files

Typing `@` followed by a path attaches that file to the prompt, so the model
has it before its first token rather than after a `read` tool call:

```
> explain @lib/lemieux/turn.ex and how it differs from @lib/lemieux/session.ex
```

In the terminal UI, `@` opens a file picker over the session's working
directory. Typing after it searches the whole repository fuzzily, skipping
what `.gitignore` ignores and ranking file-name matches first; an empty query
or a trailing `/` lists a directory instead. Tab completes, and completing a
directory descends into it. Connected MCP servers' resources appear too, as
`@server:uri`. Ctrl-V attaches an image from the clipboard the same way: it
is saved under `.lmx/pastes/` (which ignores itself for git) and inserted as
an `@path`. `@` also expands in `lmx run` and in any embedded host, because
the session does the expansion.

| Form | Attaches |
| --- | --- |
| `@lib/turn.ex` | One file, numbered the way the `read` tool numbers it |
| `@lib/` | One directory listing, one level deep |
| `@lib/**/*.ex` | Every file the glob matches, up to 25 of them |
| `@"src/my file.ex"` | A path with spaces in it |
| `@shot.png` | An image, as image bytes |
| `@paper.pdf` | A document, where the provider accepts one |
| `\@lib/turn.ex` | Nothing: the backslash suppresses the reference |

Two rules keep the feature quiet:

- **A bare word is only a reference if it names a file.** `@spec` and
  `@moduledoc` in a pasted snippet resolve to nothing and say nothing. A path
  that committed to being one (it has a separator, an extension or quotes)
  is reported when the file is missing.
- **A bare word never expands to a directory.** Ask for one with `@test/` or
  `@./test`.

Attachments are bounded: 60 KB per file, 200 KB per prompt, and five images
or documents of up to 3.5 MB each. Anything past a limit is reported rather
than dropped in silence.

A file attached to a prompt is sent again with every request for the rest of
the conversation, so only the newest three prompts that carried attachments
keep them; older ones carry a note naming the file, and the model reads it
again with `read` if it still needs it. `/context` draws what is filling the
window; see [Terminal UI](terminal-ui.md#context-draws-the-window).

## One-shot command

```sh
lmx run "PROMPT" [OPTIONS]
```

`lmx run` answers one prompt and exits. It is the form for scripts and CI.

**Standard output holds only the answer.** In the default text format, the
model's final answer is written to standard output once the prompt finishes;
the narration a model writes between tool calls stays in the transcript.
Everything else goes to standard error, one line each, starting `lmx:`:

```text
lmx: session 01K2QF8YV3RB4TJ6WQ0N7XZDP5 · wayne-gretzky · anthropic:claude-sonnet-5 (200k-token window)
lmx: read lib/lemieux/turn.ex
lmx: usage: 18234 tokens in (12000 cached) · 512 out · $0.0123
```

- At the start: the session id, its name and the model, with the model's
  context window when it is known. When nothing knows the window, a second
  line says so, that compaction assumes 128,000 tokens meanwhile, and what to
  do about it: for an Ollama model, set `OLLAMA_CONTEXT_LENGTH` for the
  server; for any other, pass `--context-window N`.
- While it works: one line per tool call (the tool and its first argument),
  per automatic retry, and while it waits for MCP servers. At the first
  command whose changes `/undo` cannot record (outside a git repository,
  say), a line after the command's own says that `/undo` covers file-tool
  edits only there.
- On the context window and compaction: `lmx: compacted the conversation:
  about A → B tokens`, `lmx: compaction failed, so nothing was cut: …`,
  `lmx: the request did not fit the context window; compacting once and
  sending it again`, a warning when the window is too small to work in, and
  `lmx: summarising made no room: …` when a summary left the next request
  over the size the session compacts at.
- After the answer: the tokens in (and how many were cached), the tokens
  out, and the cost, or `cost unknown`.
- On failure: one sentence saying what went wrong. When the run stops before
  a session exists, configuration warnings come first, because they are
  often the reason: `lmx: ollama:llama3.2, the model you last chose, is not
  available (Ollama did not answer); …`. An answer cut off at the model's
  output limit stays on standard output, and the sentence says `the answer
  did not complete: it was cut off at the model's output limit; lmx run
  --resume ID continue picks up where it stopped`.

Log lines reach neither stream unless `LMX_LOG_LEVEL` is set; see [Logs,
crash dumps and signals](#logs-crash-dumps-and-signals).

```sh
lmx run "List the public modules" > modules.txt
```

On a terminal, the answer and every standard-error line are cleaned of escape
sequences and control characters (newlines and tabs stay), because an answer
can repeat whatever a file or a web page talked the model into. Redirected to
a file or a pipe, the answer is written exactly.

**The prompt** is the arguments, joined. A `-` among them stands for standard
input; with no prompt arguments at all, piped input is the prompt. A terminal
is never read: `lmx run` with nothing to read says `run needs a prompt`.

```sh
git diff | lmx run "Review this change:" -
lmx run < task.md
```

There is no `ask_user` tool in this mode, because nobody is guaranteed to be
there to answer, and a call that would wait for approval (from `--permission-mode`
or a hook that answers `ask`) is refused. Use the terminal UI or an embedded
host for work that needs you.

**Workspace.** A new session loads the repository's workspace by default, as
the terminal UI does: instructions (`AGENTS.md`, `CLAUDE.md` and their
imports), memory, skills and selected plugins. `--bare` leaves it out, and so
do `--system` (a caller who wrote the whole system prompt meant all of it),
`--build-ext` and `--extension-profile`; a run that leaves out plugins you
saved names them. With `--config none` and no `LMX_HOME`, personal
instruction files are not read and plugins get a temporary data directory
for the run. Remote marketplace checkouts still use the platform's user cache,
and the transcript is still written ([Running with no
configuration](configuration.md#running-with-no-configuration)).

**Model and credentials.** Without `--model`, `lmx run` starts on the model
the terminal UI would ([Which model lmx starts on](#which-model-lmx-starts-on)).
Two mistakes stop it before any session or transcript exists:

- A model specification that does not parse, or names a provider `lmx` does
  not know, exits 2: `gpt-4o is not a model specification: write
  PROVIDER:MODEL, for example anthropic:claude-sonnet-5 (lmx help models)`.
- A missing key exits 3 and names what to set: `no API key for openai: set
  OPENAI_API_KEY, or choose another model with --model PROVIDER:MODEL (lmx
  help models)`. When nothing named a model and no key or local model was
  found, it says `no model credentials found: set a provider's API key, such
  as ANTHROPIC_API_KEY or OPENAI_API_KEY …`.

From a source checkout, these sentences say `mix lmx help models`.

**Continuing.** `lmx run -c "…"` resumes the newest session that ran in this
directory, or starts a new one and says so on standard error.
`lmx run --resume SESSION "…"` resumes a named one; using both, or naming
no stored session, is a usage error. A resumed session takes its configuration from its transcript; if
that recorded a workspace layer, today's workspace replaces it, as in the
terminal UI.

### Output formats

`--output-format text` is the default: the answer on standard output,
everything else on standard error.

`--output-format json` writes one object when the prompt ends, whether it
succeeded or not:

```json
{"type": "result", "session_id": "01K…", "model": "anthropic:claude-sonnet-5",
 "text": "the answer", "stop_reason": "stop",
 "usage": {"input_tokens": 1200, "output_tokens": 80, "…": 0},
 "error": null, "exit_status": 0}
```

On failure, `error` is `{"category": "auth", "message": "…"}`, with the
category `usage`, `auth`, `limit`, `cancelled`, `provider` or `other`, and
`text` holds whatever answer was produced, possibly a partial one. A failure
before any session exists, such as a missing prompt, a model specification
that does not parse or a missing key, writes the same object with
`session_id` null. A command line `lmx` cannot parse (an unknown flag, a
flag value it does not accept, or a config file or limit it cannot read) is
refused before it knows the output format, so no object is written: the
sentence goes to standard error only.

`--output-format stream-json` writes one JSON object per line as the work
happens, and ends with the same `result` object:

| `type` | Fields |
| --- | --- |
| `session` | `session_id`, `name`, `model`, `context_window` (tokens, or null when unknown) |
| `notice` | `text`: a configuration warning, a startup notice, or a notice about the context window (unknown, too small, or a summary that made no room) |
| `text` | `text` (a streamed fragment of any request, narration included) |
| `tool_call` | `id`, `name`, `arguments` |
| `tool_result` | `id`, `name`, `error` (boolean), `output` (first 2,000 characters), `output_bytes` |
| `retry` | `attempt`, `max`, `delay_ms`, `after_output`, `message` |
| `waiting_for_mcp` | `servers`, `timeout_ms` |
| `error` | `category`, `message` |
| `result` | as in `json` |

Both JSON formats keep the model's text exactly; DEL and C1 control
characters are escaped as `\u00XX`. In `stream-json`, standard error carries
nothing for the run itself, though a failure before a session exists still
writes its sentence there.

### Exit status

| Status | Meaning |
| --- | --- |
| 0 | the answer was produced |
| 1 | anything else: an unexpected error, a session open in another `lmx`, an answer cut short (`length`) |
| 2 | usage: a flag, an argument, a missing prompt, a model specification, a `--resume` that names no stored session, or the configuration was wrong |
| 3 | credentials: no API key, or the provider refused the one given |
| 4 | a limit stopped the work: requests, spend, turns, or no progress |
| 5 | the work was cancelled |
| 6 | the provider failed or refused, after the session's own retries |

The installed `lmx` exits 130 when Ctrl-C stopped it, 129 when its terminal
closed and 143 for SIGTERM; see [Signals](#signals-and-closed-terminals).

## Which model lmx starts on

When no `--model`, `LMX_MODEL`, config `"model"` or Ixway route names a
model, `lmx` tries, in order:

1. the model you last chose, if it can still be reached: its provider has a
   key, or, for an `ollama:` model, the daemon serves it. "Chose" means a
   terminal UI session started on it because you named it: with a flag,
   `LMX_MODEL`, the config file or an Ixway route, or with `/model` or
   `/provider` after a start that failed. A model you switch to in a running
   session, or name for `lmx run`, is not remembered;
2. the recommended model of the first provider whose key is set, in this
   order: Anthropic, OpenAI, Google Gemini, xAI, OpenRouter, DeepSeek, Z.AI
   Coding Plan (`lmx help models` lists each one's model and variable);
3. a model the local Ollama daemon serves that can call tools, with a notice
   that says so and that the daemon's context length needs raising (see [Use
   a local model](providers.md#use-a-local-model));
4. nothing usable: the terminal UI opens its provider panel with no provider
   preselected, and `lmx run` exits 3 with a sentence that names your
   choices.

`--config none` without `LMX_HOME` skips steps 1 to 3 and starts on
`anthropic:claude-sonnet-5` unless `--model` or `LMX_MODEL` names another.
`lmx explain` reports the model and what chose it (`model_source`).
[Configuration](configuration.md#which-model-lmx-starts-on) has the details.

## Working directory and continuing

- `-C DIR` / `--cwd DIR` runs any command as if `lmx` had been started in
  `DIR`: its tools, the repository's instructions and `.mcp.json`, and
  `--continue`. Other paths on the command line are still read from where you
  ran `lmx`.
- `-c` / `--continue` (terminal UI and `lmx run`) resumes the newest session
  that ran in this directory. `/resume` lists sessions by last activity.
- A flag that belongs to another command is named as such (`--model does not
  apply to lmx log`), and a missing or mistyped value says so.
- A prompt goes to `lmx run`, to the terminal UI with `--prompt`, or into
  the terminal UI once it is open. `lmx "fix the bug"` (one quoted argument
  where a command goes) exits 1 with `lmx: "fix the bug" is not a command`
  and the commands that would have worked: `to ask once and exit: lmx run
  'fix the bug'; to open the terminal UI with it: lmx --prompt 'fix the
  bug'`. Flags you typed and `-C DIR` are repeated, quoted for the shell; a
  line longer than 60 characters is shown as `lmx run [options] PROMPT`. A single unknown word, or several unquoted
  ones, gets `unrecognised arguments` and the usage: `lmx resume 01ABC`
  most likely meant `--resume`.
- The terminal UI takes no command words on its command line, and a prompt
  only through `--prompt`: `lmx tui fix the tests` names
  `lmx --prompt 'fix the tests'` and the `lmx run` line.

## Common options

Options work with the terminal UI and `lmx run` unless a row says otherwise.
`lmx help options` prints the flags `lmx --help` leaves out; the MCP OAuth
flags are in `lmx help mcp` and the builder flags in `lmx help learning`.

| Option | Meaning |
| --- | --- |
| `-m, --model PROVIDER:MODEL` | Select the model; without one, see [Which model lmx starts on](#which-model-lmx-starts-on) |
| `-C, --cwd DIR` | Run as if started in `DIR` |
| `-c, --continue` | Resume the newest session that ran in this directory |
| `--resume SESSION` | Continue a stored session, by id or name |
| `--prompt TEXT` | Terminal UI only: send `TEXT` as the first message once the session is up ([with a first prompt](#terminal-ui)) |
| `--permission-mode MODE` | Ask before tools change things: `ask`, `accept_edits`, `auto`, `full_auto` or `read_only`. Off by default, so tools run without asking (`lmx help permissions`) |
| `--sandbox` | Run commands in macOS Seatbelt or Linux bubblewrap (`lmx help sandbox`) |
| `--config PATH` | The personal JSON configuration; default `~/.lmx/config.json`. `none` reads no config file and, unless `LMX_HOME` is set, keeps no state (no history, checkpoints, log or remembered model); transcripts, MCP tokens and crash dumps still go under `~/.lmx` unless their own options move them ([Running with no configuration](configuration.md#running-with-no-configuration)) |
| `--max-turns N`, `--max-requests N`, `--max-cost-usd N` | [Session limits](#session-limits) |
| `--router direct\|ixway\|NAME` | Override the primary inference route: direct, Ixway, or a [model route an extension registers](extensions.md#adding-a-model-route) |
| `--ixway URL` | Use the [Ixway inference pipeline](ixway.md) with an instance origin |
| `--base-url URL` | Use a provider-compatible API gateway (not an HTTP proxy) |
| `--system TEXT` | Replace the base system prompt; the terminal UI still adds its workspace layer, `lmx run` runs bare |
| `--mcp-config PATH` | Attach the MCP servers in this file instead of the repository's `.mcp.json` |
| `--project-mcp` | Trust the repository's `.mcp.json` for this run, without asking |
| `--no-project-mcp` | Never start the repository's `.mcp.json`, even if it was trusted |
| `--hooks PATH` | Load command hooks: `lmx`'s version-1 hooks file, or a Claude Code settings file's `"hooks"`; unsupported fields are listed in [Hooks](hooks.md#claude-code-settings-files) |
| `--extension NAME` | Load your own extension from `~/.lmx/extensions/NAME`; repeatable. `"extensions": ["NAME"]` is the persistent form ([Extensions](extensions.md#installing-an-extension-into-lmx)) |
| `--extension-dir PATH` | Load the extension in `PATH`; repeatable. The only way a directory inside a checkout is loaded |
| `--no-user-extensions` | Leave out configured and command-line extensions of your own |
| `--context-window N` | How many tokens the model's window holds, for planning compaction; needed only for a model nothing knows about. For Ollama, the server's own window (`OLLAMA_CONTEXT_LENGTH`) decides what the model sees, and a smaller served window wins |
| `--web-search brave\|none` | Choose the web-search backend, or turn search off. With neither flag, setting nor variable, search is on whenever a Brave key is set |
| `--web-fetch` / `--no-web-fetch` | Turn page reading on or off; on by default whenever web search is on. Loopback, private and link-local addresses are refused |
| `--sessions-dir PATH` | Where transcripts are written |
| `--elixir` | Use the Elixir evaluator as the built-in tool; the terminal UI keeps `ask_user` |
| `--no-delegate` | Withhold the read-only [repository scout](#delegated-repository-investigation) |
| `--no-mouse` | Give the mouse back to the terminal (terminal UI only) |
| `--output-format text\|json\|stream-json` | `lmx run` only; see [Output formats](#output-formats) |
| `--bare` | `lmx run` only: leave the workspace out |
| `-h, --help` / `-v, --version` | Help, or the version |

Workspace options add to the discovered workspace for one session:

| Option | Meaning |
| --- | --- |
| `--skill-dir PATH` | Add an Agent Skills root; repeatable |
| `--plugin-dir PATH` | Add an already-installed local plugin; repeatable |
| `--marketplace SOURCE` | Read a marketplace catalog: a local directory, GitHub `OWNER/REPO`, a Git URL or a direct `marketplace.json` URL; repeatable |
| `--plugin NAME@MARKETPLACE` | Fetch and enable a plugin from a marketplace you named; `MARKETPLACE` is the catalog's `name` field; repeatable |

`lmx plugin install` saves a plugin for every session instead; see
[Plugins](configuration.md#claude-compatible-plugins-and-marketplaces).

MCP OAuth options (`lmx help mcp`):

| Option | Meaning |
| --- | --- |
| `--credentials PATH` | Where MCP OAuth tokens are kept; default `~/.lmx/mcp-credentials.json` |
| `--oauth-callback-port N` | The loopback port the browser returns to; default 8642 |
| `--oauth-client-id ISSUER=ID` | A client id you registered by hand; repeatable |

The experimental builder and profile flags (`--build-ext`, `--quota`,
`--extension-profile`) are in `lmx help learning`. They select a fixed
session profile, so they refuse flags that would rewrite it: `--system`,
`--elixir`, `--delegate`, `--mcp-config`, `--resume`, the web flags and the
skill and plugin flags; `--extension-profile` also refuses `--model`.

## Session limits

```sh
lmx --max-turns 20 --max-requests 50 --max-cost-usd 2.50
```

Flags beat `LMX_MAX_TURNS`, `LMX_MAX_REQUESTS` and `LMX_MAX_COST_USD`, which
beat `max_turns`, `max_requests` and `max_cost_usd` in the config file. Counts
must be positive integers; the dollar ceiling may be zero. An invalid value
stops before a session starts, with a sentence that names the flag and the
variable; an empty or blank variable counts as unset, so the config file's
value applies.
`lmx explain` shows the limits in effect under `settings`.

- `max_turns` (default 400) bounds one prompt.
- `max_requests` counts the session's own provider requests, retries and
  compaction included. The repository scout's requests have their own caps
  ([below](#delegated-repository-investigation)); use `--no-delegate` when
  one number must bound every request.
- `max_cost_usd` stops before a request whose estimated cost could pass the
  ceiling. Missing pricing, an unknown estimate or unknown earlier spend also
  stops it, rather than counting as zero, and the stop names the model whose
  price is missing. A model whose catalog tariff cannot be resolved for the
  request is estimated, and its usage priced, at the model's list rates; the
  usage says so (`pricing.status` is `list_rates`). This is an estimate the
  runtime enforces, not a limit the provider enforces on your bill; use a
  request limit when a route cannot price requests.

On resume, the limits you give now replace the recorded ones, limits you omit
keep their recorded values, and requests and spend already made still count.
An embedding host sets its own limits through its session options.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `LMX_MODEL` | Model for new sessions (`PROVIDER:MODEL`) |
| `LMX_CONFIG` | Personal config file, or `none`: no config file, and no state unless `LMX_HOME` is set; transcripts are still written ([Running with no configuration](configuration.md#running-with-no-configuration)) |
| `LMX_HOME` | The state directory: the model you last chose and recently used models, input history, checkpoints, MCP trust and permission decisions, and logs. Default: the config file's directory, `~/.lmx`. Crash dumps go to `crash/` under `LMX_HOME`, else to `~/.lmx/crash` whatever the config file. Transcripts, MCP tokens and your own extensions stay under `~/.lmx` unless their own variables below move them |
| `LMX_SESSIONS_DIR` | Transcript directory; default `~/.lmx/sessions` |
| `LMX_EXTENSIONS_DIR` | Where `--extension NAME` looks; default `~/.lmx/extensions` |
| `LMX_MAX_TURNS`, `LMX_MAX_REQUESTS`, `LMX_MAX_COST_USD` | [Session limits](#session-limits) |
| `LMX_PROJECT_MCP` | `1` trusts the repository's `.mcp.json` for the run; `0` never starts it |
| `LMX_DELEGATE` | `0` withholds the repository scout |
| `LMX_WEB_SEARCH` | `brave` selects web search; `none` turns it off |
| `LMX_WEB_FETCH` | `1`, `true` or `yes` turns page reading on; `0`, `false`, `no` or empty turns it off |
| `BRAVE_SEARCH_API_KEY` | Brave Search key; wins over a saved one, and an empty value ignores the saved one |
| `LMX_ROUTER` | Primary inference route: `direct`, `ixway` or a registered route's name |
| `LMX_BASE_URL` | Provider-compatible API base URL |
| `LMX_IXWAY_URL` | Ixway instance origin; needs a gateway key from the environment or the config |
| `IXWAY_API_KEY` | Ixway gateway key, used only on Ixway routes |
| `OLLAMA_API_KEY` | Ollama Cloud key; also turns on the terminal UI's Cloud catalog |
| `JEV_API_KEY` | TypeSafe's Jev key; switches on [System One compaction](configuration.md#system-one-compaction) through the `typesafe` provider where it is bundled: the installed `lmx`, or a source run from `dist/lmx` |
| `LMX_CREDENTIALS` | MCP OAuth token file; default `~/.lmx/mcp-credentials.json` |
| `LMX_OAUTH_CALLBACK_PORT` | MCP OAuth callback port; default 8642 |
| `LMX_CHECK_UPDATES` | `0` turns the installed `lmx`'s automatic update checks off (at start, after `/new` and `/resume`, and hourly); `/update` still checks |
| `LMX_AUTO_UPDATE` | `0` stops the installed `lmx` installing updates on its own: it still says one is available, and `/update` installs it, after the same signature check |
| `LMX_LOG_LEVEL` | `debug`, `info`, `warning`, `error` (also `emergency`, `alert`, `critical`, `notice`, `none`): the log level, and log lines are then also printed on standard error, except over the terminal UI's screen ([Logs](#logs-crash-dumps-and-signals)) |
| `NO_COLOR` | Any non-empty value starts the terminal UI in the `mono` theme, unless a theme was chosen; a startup notice and `/theme` say it is in effect, since it is often inherited from a launcher or an agent's shell |
| `COLORTERM` | `truecolor` or `24bit` makes the terminal UI draw 24-bit colour instead of the 256-colour palette (not inside GNU screen) |
| `VISUAL`, `EDITOR` | The editor Ctrl-G opens |
| `OMARCHY_PATH` | Where Omarchy is installed; its `default/agents/skills` are read as [Omarchy's skills](configuration.md#agent-skills-and-legacy-commands) |
| `ERL_CRASH_DUMP` | Where a crash dump goes; `lmx` sets `~/.lmx/crash/erl_crash.dump` (`crash/` under `LMX_HOME`) unless you set it ([Crash dumps](#crash-dumps)) |

**Empty values.** An empty or blank `LMX_MODEL`, `LMX_WEB_SEARCH`,
`LMX_ROUTER`, `LMX_BASE_URL`, `LMX_IXWAY_URL`, `LMX_CONFIG`, `LMX_HOME`,
`LMX_SESSIONS_DIR`, `LMX_EXTENSIONS_DIR`, `LMX_CREDENTIALS`,
`LMX_OAUTH_CALLBACK_PORT`, `LMX_LOG_LEVEL`, `LMX_CHECK_UPDATES`,
`LMX_AUTO_UPDATE` or limit variable counts as unset: a blank limit falls
through to the config file, and a blank
`LMX_EXTENSIONS_DIR` means `~/.lmx/extensions`. The switches
`LMX_WEB_FETCH`, `LMX_PROJECT_MCP` and `LMX_DELEGATE` read an empty value as
off.

**Provider keys** are read by `req_llm` from the usual variables:
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `XAI_API_KEY`,
`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` and `ZAI_API_KEY` for the providers
`lmx help models` lists; see each provider's `req_llm` documentation for
others. A key in the environment wins over one saved in `~/.lmx/config.json`,
and an empty one counts as no key and switches the saved one off. Commands,
hooks and MCP servers do not see variables whose names contain `KEY`,
`TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` unless `"credential_allowlist"`
names them ([Credential scrubbing](configuration.md#credential-scrubbing)).

**What commands inherit.** Commands the agent runs, command hooks and MCP
stdio servers get the environment you started `lmx` in, less those
credential-shaped variables. Under the installed `lmx` that is your own
environment, `PATH` included, so your `erl`, `elixir` and `mix` are the ones
that run, and none of the variables the release sets for its own runtime.
The editor Ctrl-G opens gets your environment as it is. [What commands
inherit](configuration.md#what-commands-inherit) has the details.

**`.env` files.** The installed `lmx` never reads a `.env` file, whatever
directory it starts in: a cloned repository's `.env` could otherwise run
commands and redirect your keys before any trust question. Keep keys in your
shell's environment or in `~/.lmx/config.json`. A source run from the
repository root (`mise exec -- mix lmx …`, `mix lmx.tui`) loads the
checkout's own `.env`, and a variable already set in your shell wins over it;
a source run from `dist/lmx` reads no `.env`, as the installed `lmx` does not.
The checkout's `.env.example` is all comments, so copying it sets nothing:
uncomment only the lines you fill in, because an empty key switches off a
saved one.

Flags beat environment variables, which beat the config file, for a new
session. A resumed session keeps more of its recorded configuration; see
[Resume precedence](configuration.md#resume-precedence).

## Logs, crash dumps and signals

### Logs

By default, `lmx` writes log lines only to a file in the state directory,
never to the terminal or into `lmx run`'s output:

```text
~/.lmx/logs/lmx.log        (rotated at 1 MB, three old files kept)
```

The state directory is `LMX_HOME` when set, else the config file's directory
(`--config PATH` or `LMX_CONFIG`), else `~/.lmx`. With `--config none` and no
`LMX_HOME` there is no log file. The `logs` directory is private (`0700`), and
so is a state directory `lmx` has to create. `lmx explain` reports the file
as `diagnostics.log_file`.

The default level is `error`, because `lmx` already says what went wrong as
a sentence. `LMX_LOG_LEVEL=debug` (or `info`, `warning`) raises the level of
the file and also prints the lines on standard error:

```sh
LMX_LOG_LEVEL=debug lmx run "reproduce the failure" 2> debug.log
```

The terminal UI keeps the lines off its screen: while it is open and
standard error is the terminal, they go to the log file only, and standard
error gets them again once the screen closes. To watch them while it runs,
read the log file, or redirect standard error when you start it, as in
`LMX_LOG_LEVEL=debug lmx 2> lmx-debug.log`. On Windows (experimental),
standard error gets no lines while the screen is open, redirected or not.

At `warning` and below, a failed request's log report can include the
provider's response headers, cookies among them. Check a log before you share
it.

### Crash dumps

If the runtime itself crashes, it writes `erl_crash.dump` to the private
directory `~/.lmx/crash/` (`crash/` under `LMX_HOME` when that is set) rather
than into your project. That holds for the installed `lmx` and for every
`mix lmx` command from a source checkout, `--config none` included. A dump
holds whatever the runtime held, provider keys and transcript text included:
never attach one to a public issue. Set `ERL_CRASH_DUMP` to choose another
place.

Under the installed `lmx`, commands the agent runs do not inherit the
`ERL_CRASH_DUMP` that `lmx` chose for itself, so an Erlang or Elixir program
of yours that crashes writes its dump where it would without `lmx`. If you
set `ERL_CRASH_DUMP` yourself before starting `lmx`, both `lmx` and your
commands use your value. From a source checkout, commands inherit the
variable, so such a dump lands in `~/.lmx/crash` too (under `--sandbox`,
which hides `~/.lmx`, it is not written).

### Signals and closed terminals

The installed `lmx` handles Ctrl-C, a closed terminal and SIGTERM (`kill PID`)
the same way: it cancels the running turn, records the cancellation in the
transcript, stops the command the agent was running (its whole process
group), and exits. A turn in flight gets up to three seconds to record its
cancellation. The exit status says which it was: 130 for Ctrl-C, 129 for a
closed terminal, 143 for SIGTERM. If the `lmx` launcher itself is killed
outright (`kill -9`, `timeout -s KILL`), its runtime notices within about a
second and stops the same way: the terminal UI leaves its screen, and
`lmx: the launcher is gone; stopping` is written on standard error. If the
runtime is the one killed, the launcher puts the terminal back. `nohup lmx …`
keeps working.

From a source checkout, Mix owns the signals: Ctrl-C in `mix lmx run` opens
the BEAM's BREAK menu, and closing the terminal ends the VM at once. SIGTERM
to the VM running the terminal UI (`kill PID` on `mix lmx`) leaves the
screen and restores the terminal, stops the session so its `sessionEnd`
hooks run, prints the resume hint when there is something to resume, and
exits 0.

In the terminal UI, Ctrl-C is a key rather than a signal: it cancels the turn,
and pressed twice while idle, it quits. A killed `lmx` cannot always put the
terminal back; [Troubleshooting](troubleshooting.md#the-terminal-is-garbled-after-lmx-was-killed)
says how to recover.

## Transcripts, resume, and fork

Every session is stored as a transcript: an append-only file of everything
that happened, in `~/.lmx/sessions` (or `--sessions-dir`). Resuming, forking
and `lmx log` all read it. Transcript commands make no model call and work
offline.

### SESSION is an id or a name

Every session has two names: the id it is stored under (a ULID such as
`01K2QF8YV3RB4TJ6WQ0N7XZDP5`), and a name derived from it: a hockey player's,
such as `wayne-gretzky` or `marie-philip-poulin`. Anywhere a command takes
`SESSION`, either works. The names come from public NHL and PWHL roster
listings, plus five earlier CWHL players documented by the Hockey Hall of
Fame. Lemieux is not affiliated with or endorsed by the NHL, the PWHL or the
Hockey Hall of Fame. Names that read as crude are withheld and never
generated.

The name is computed from the id, not stored, so every machine gives a
session the same name. `lmx run` prints both; the terminal UI shows the name,
because that is the one worth writing down. If two stored sessions share a
name, `lmx` says so and lists their ids rather than guessing. Older forms of
names (earlier first-name/surname pairs, the original three-surname form such
as `gretzky-fleury-orr`, and names that are now withheld) are still accepted,
so a name you wrote down still opens its session.

A delegated child's session is an ordinary session in the same store.
`/resume` does not offer them, but resuming one by id works, which is how you
read what a scout actually did, and `lmx log` shows them all.

### Read a conversation

```sh
lmx log SESSION
lmx log SESSION --jsonl
```

`lmx log` abbreviates large tool results and omits thinking blocks so you can
follow the conversation; on a terminal its output is cleaned of escape
sequences. Each `— MODEL, tools: … —` header names the tools offered in the
next request. `--jsonl` prints every entry exactly, as JSON lines.

### Continue a session

```sh
lmx --resume SESSION
lmx run --resume SESSION "Continue with the next failing test"
lmx run -c "Now fix the next one"
```

A resumed session is given the conversation itself: the model sees every
earlier prompt, answer and tool result, rebuilt from the transcript, and the
terminal UI redraws it and refills its input history. The transcript restores
the model, system prompt, tools, disabled tools, reasoning settings and MCP
servers; flags you pass override them. The workspace layer of the system
prompt is refreshed from today's files when the transcript recorded one.
Hooks, credentials and routing always come from the current host.

A transcript written by a build this one cannot read is refused with a
sentence saying so, and left exactly as it was; see [Transcript
compatibility](transcript-compatibility.md).

### Start over without leaving

`/new` starts a separate session with the startup configuration: a new id and
name, an empty transcript and usage at zero. The previous transcript stays
stored for `/resume`, `lmx log` and `lmx fork`. If the new session cannot
start, the current one stays open. `/new` waits for a running turn to finish.

### Inspect a canonical request

Each model request is recorded with its own request id. Find them in the raw
JSONL and print one:

```sh
lmx log SESSION --jsonl \
  | jq -r 'select(.type == "request") | .payload.id'

lmx request SESSION REQUEST_ID
```

The snapshot holds the resolved system text and its digest, the exact
conversation entry ids, the model, tool names, descriptions and schemas, safe
parameters, the output schema and the Lemieux and `req_llm` versions.
Credential-shaped parameters are redacted.

### Fork a session

With no cut, fork copies the whole transcript and prints the new id:

```sh
NEW_SESSION=$(lmx fork SESSION)
lmx --resume "$NEW_SESSION"
```

Cut after a completed assistant turn:

```sh
lmx fork SESSION --at-turn 2
```

`--at ENTRY_ID` and `--at-seq N` cut at an exact entry or sequence number.
A cut inside an unfinished turn is refused; `--unsafe` permits it for
recovery work, but the result may not be a conversation a provider accepts.

## Plugins, extensions and MCP servers

| Command | What it does |
| --- | --- |
| `lmx plugin install PATH\|GIT-URL` | Saves a plugin in `"plugin_dirs"`, so every session selects it; a Git URL is cloned into `~/.lmx/plugins/NAME` first |
| `lmx plugin list` / `remove NAME\|PATH` | Lists or forgets saved plugins; cloned files stay |
| `lmx extension new NAME [--dir D]` | Writes a one-file script extension under `~/.lmx/extensions/NAME` |
| `lmx extension list` | Says, for each installed extension, whether this `lmx` would load it |
| `lmx mcp list` | Your servers, and whether the repository's `.mcp.json` is trusted |
| `lmx mcp trust [--yes]` / `untrust` | Shows what the repository's servers would run; records trust only with `--yes` |
| `lmx mcp import claude\|codex` | Copies servers into `"mcp_servers"`: from Claude Code, the user-scope servers in `~/.claude.json`; from Codex, `~/.codex/config.toml`. Servers you already have keep what you wrote |

Selecting a plugin is the decision to trust it: its hooks run and its MCP
servers start in every session. `lmx mcp import claude` leaves out Claude
Code's local-scope servers (the default scope of `claude mcp add`, kept per
project and often with that project's credentials) and names them, because
imported servers start in every session everywhere; add one to the
repository's `.mcp.json` or pass `--mcp-config` to use it there. A plugin or
marketplace that cannot be loaded is a notice, and the session starts
without it. [Configuration](configuration.md#claude-compatible-plugins-and-marketplaces)
covers marketplaces, caching and what is supported.

## Delegated repository investigation

```sh
lmx                      # the scout is there by default
lmx --no-delegate        # and this is how you decline it
```

A new session gets a `delegate` tool with one definition, the repository
scout: a read-only helper session the model can send to investigate the
repository while it keeps working. The model may run one to three at once.
Each scout uses the session's model (or `"scout_model"`), gets only `read`,
`grep` and `glob`, and stops when it runs out of turns (400), when a progress
check every two minutes finds it stalled, or after an hour. Spending is
capped: $3.00 per scout on routes that can price a request (480 requests
otherwise) and $9.00 or 2,880 requests for all of a session's scouts
together. On priced routes each scout response is capped at 8,192 tokens.

The scout is on so that a request to "use a subagent" gets one rather than
"no subagent tools are available". It costs tokens: on read-heavy questions,
sessions that delegated spent about five times the tokens for answers no
better. `--no-delegate`, `LMX_DELEGATE=0` or `"delegate": false` declines
it, in that precedence; `/delegate off` and `/delegate on` switch it for the
current session. A resumed session gets it only with `--delegate`, because
definitions are not restored from a transcript. `--elixir` keeps it.

Claude Code agent definitions (`.claude/agents/*.md` in the repository or
`~/.claude/agents`, and a selected plugin's agents) are offered through the
same tool as more read-only investigators. A definition that asks for a tool
that could change things has that tool refused, with a notice. Scouts never
delegate further, run commands or write.

## Elixir-only mode

```sh
lmx run --elixir "find every GenServer here"
```

`--elixir` is a tool profile: it replaces `read`, `write`, `edit` and `bash`
with an Elixir evaluation tool. The terminal UI keeps `ask_user` beside it,
and `/elixir` toggles the same pair; MCP tools you configured still compose
with it.

Evaluation runs on a separate BEAM node with the same user, files and
network. That protects the session's own processes, but it is not an
operating-system sandbox. `/attach NODE` gives up even that separation, so
the evaluator can inspect a running application. The installed release
contains real code directories, so the separate node works from the binary
as well as from a source checkout.

## Harness-learning and feedback commands

**Experimental.** These commands serve harness learning and evaluation, not
everyday work, and may change in any 0.x release. The [learning
guides](harness-learning.md) explain when to use them; `lmx help learning`
lists them.

### Anchored feedback

```sh
lmx feedback SESSION --text "It should have run the formatter" \
  --scope project --standing-rule
```

Feedback is written to a ledger of its own, never to the transcript: a
`feedback/` directory beside the sessions directory (`~/.lmx/feedback` by
default; `--feedback-dir` chooses another). `--entry ID` anchors it to an
exact transcript entry, otherwise to the latest; without `--text` it reads one
line from standard input. Scopes are `task`, `project`, `tenant` and
`global`. Recording feedback changes nothing by itself: it does not ask the
agent to change, add a case to a corpus or activate anything.

`lmx feedback --mine SESSION [--model SPEC]` lets the model record feedback
instead: one tool-less request reviews the stored transcript and records each
opportunity it names, marked as model-made. A reasoning model can spend its
whole output budget thinking and record nothing; `--max-tokens N` raises the
budget and `--reasoning-effort LEVEL` sets the effort.

A reviewed record becomes a case draft:

```sh
lmx feedback draft-case FEEDBACK_ID --source DIR --output DIR \
  --prompt P --verifier CMD [--class mechanical|environmental]
```

This freezes a fixture and a verifier beside the record as an unapproved
draft. Secret-shaped files (`.env`, keys, credential files) are not copied
into the fixture; the draft lists them for review.

### Corpus promotion

```sh
lmx corpus promote DRAFT_DIR MANIFEST --cluster ID [--tag T]... \
  [--allow PATH]... [--expect pass] [--repos-dir D] [--allow-secret-files]
```

Promotion adds a reviewed draft to a corpus manifest. It first proves the
grader fails on the untouched fixture, and refuses a case whose grader passes
there unless `--expect pass` says that is intended (read-only and refusal
cases). A fixture holding a secret-shaped file is refused, naming the files,
unless `--allow-secret-files` says you put them there on purpose. Nothing here
runs a model.

### Harness-learning inspection

Verify versioned, digest-bearing contracts without starting a session:

```sh
lmx harness verify snapshot snapshot.json
lmx harness verify run run-evidence.json
lmx harness verify bundle experience-bundle.json
lmx harness verify discovery-plan plan.json
lmx harness verify candidate candidate.json
lmx harness verify evaluation evaluation.json
lmx harness verify frontier frontier.json
lmx harness verify state state.json
lmx harness verify exposure exposure.json
lmx harness verify experiment-plan experiment-plan.json
```

Materialize an authorized experience bundle from local artifact bytes:

```sh
lmx harness materialize bundle.json ARTIFACT_DIR DESTINATION
```

Artifact files are named by reference id or SHA-256. The command checks
scope, paths, sizes and digests, writes history read-only and leaves only the
`proposal/` subtree writable. It never downloads artifacts or activates a
candidate.

Export a confirmed discovery candidate as a learned harness overlay:

```sh
lmx harness export CAMPAIGN_DIR CANDIDATE_ID \
  [--to PATH] [--unconfirmed] [--force]
```

The default destination is `.lmx/harness.json` in the current repository,
which the next session there reads. A repository's overlay may only add
system-prompt text; learned tool descriptions apply only from your own
`~/.lmx/harness.json`, so use `--to ~/.lmx/harness.json` when you want them
([Learned harness overlay](configuration.md#learned-harness-overlay)); an
export that writes tool descriptions where they will not apply says so. An
unconfirmed candidate is refused without `--unconfirmed`, and an existing file
without `--force`. Activation is your review of the file; remove or revert it
to roll back. See [Using self-improvement
regularly](harness-learning.md#using-self-improvement-regularly).

### Reflect on a session

`/reflect` in an idle terminal UI reviews the current transcript (errors,
tool outcomes, your decisions, interruptions, compaction and token use) and
answers with recommendations and proposed checks. It changes no files and
nothing about the running harness. It uses the current model and the normal
limits. It works offline from Ixway (a model connection is still needed for
the written assessment). A cancellation alone is not scored as a failure. See
[Session reflection](reflection.md).

`/reflect opportunities` asks for records instead of prose: each opportunity
the model names is written to the feedback ledger, as `lmx feedback --mine`
would, without a second paid review. A model that answers in prose records
nothing, which is not an error.

### Capture feedback without leaving the session

`/feedback` records what should have gone differently, against the moment it
went wrong, while you are still looking at it:

```
› /feedback it should have run the formatter before finishing
Which moment is this about? (blank for the most recent)
  1. #7 assistant · Done — the refactor is complete.
  2. #6 tool_result · ✓ bash mix test
  ...
› 1
What kind of feedback is this? (blank to leave it unclassified)
  1. bug — it did something wrong
  ...
```

The prose can come with the command or be typed when asked. After the anchor
it asks at most three questions (kind, reach, and once or always), each
answered with a number, a word or a blank line for the default. It writes to
the same ledger as `lmx feedback`, in the same shape, and never touches the
transcript. While it is open, every typed line is an answer; `/cancel`
discards it. It is refused mid-turn, when a typed line is a steer.
