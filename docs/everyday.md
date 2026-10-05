# Everyday use

A walk through the things you do with `lmx` every day. [First session with
lmx](getting-started.md) gets it running; the [CLI reference](cli.md) has every
command, key and option; the [trust model](../SECURITY.md#what-lmx-trusts-by-default)
says what runs without asking.

## Starting

```sh
cd /path/to/your/project
lmx            # from a source checkout: mise exec -- mix lmx -C /path/to/your/project
```

Set one provider's API key and `lmx` picks that provider's recommended model.
A model you name when you start the terminal UI (with `--model`,
`LMX_MODEL`, `"model"` in `~/.lmx/config.json` or an Ixway route) is
remembered: later starts that name no model begin on it, as long as it can
still be reached. `lmx run` remembers nothing, and neither does a switch with
`/model` or `/provider` once a session is running. With no key, `lmx` uses a
model your local Ollama serves that can call tools, or opens a panel where you
pick a provider and paste its key, which it saves in `~/.lmx/config.json`
(readable only by you). In the terminal UI, `/provider` switches provider and
`/model` picks a model within it; neither saves a key. `lmx help models` lists
the models `lmx` picks.

The header shows the version, the working directory, the session's name, the
provider, the model and the reasoning effort; the terminal's title shows
`lmx | NAME | DIR`. The startup banner states the permission mode and the
sandbox. By default that is "full auto": tools run without asking, and
commands run unsandboxed as your user, in the environment you started `lmx`
in, without your credential-shaped variables. Where `/undo` cannot record
what commands change, outside a git repository for example, a second notice
says that it covers file-tool edits only there. What `/undo` can put back,
and what it cannot, is under [Taking changes back](#taking-changes-back).

## Asking and steering

Type and press Enter. Shift+Enter inserts a newline where the terminal can
tell it apart; Ctrl-J, or a trailing `\` before Enter, always does. Ctrl-G
opens the draft in your editor (`$VISUAL`, then `$EDITOR`, then `vi`; not yet
on native Windows). `@path` attaches a file (the picker searches the
repository fuzzily and skips ignored files); Ctrl-V attaches an image from the
clipboard.

While the model works:

- **Enter** sends a steer: it reaches the model with its next request.
  `/unsteer`, or Alt-Z, takes it back before then.
- **Tab** queues a message to send after the turn, up to nine. Alt-1 to Alt-9
  select one, Alt-E revises it and Alt-U removes it.
- **Ctrl-C** or `/cancel` stops the turn. `/retry` sends a failed request
  again.

On macOS, the Alt shortcuts need the Option key to send Alt; see
[Your terminal](getting-started.md#your-terminal).

For longer tasks the model keeps a plan with its `todo` tool, shown above the
input while a task is open. A turn that took a while ends with a desktop
notification (Alt-N turns them off for the sitting).

## Seeing what happened

Edits, writes and patches are drawn as numbered unified diffs. Tool output is
shortened in the transcript; **Ctrl-O** pages through the full output of
recent calls. `/diff` shows the working tree's `git diff`, and `/context`
draws what is filling the context window. Each turn ends with a summary line:
how long it took, its requests, tokens and tool calls. A turn cut short by
the model's output limit says so at its end; send `continue` and the model
picks up where it stopped.

## Approvals and permissions

Nothing asks unless you ask for it:

```sh
lmx --permission-mode ask            # ask before edits and commands
lmx --permission-mode accept_edits   # edits run, commands ask
```

or `"permissions": {"mode": "ask"}` in `~/.lmx/config.json`. Once permissions
are on, Shift-Tab steps through the modes during a session; with them off it
reminds you how to turn them on. A call that needs you appears on an approval
card: `y` runs it, `n` with a reason refuses it (the model reads the reason),
and `a` runs it and remembers the card's suggested rule, such as
`Bash(npm test:*)`, for this repository. `/permissions` lists and edits the
remembered rules. Add `--sandbox` to run commands in an operating-system
sandbox: they write only to the working directory, temporary directories and
tool caches, reach no network beyond loopback, and cannot see credential
locations such as `~/.ssh`, `~/.aws` and `~/.git-credentials`, which the
file tools refuse too. `lmx help permissions` and `lmx help sandbox` have the
details.

## Taking changes back

- `/undo` puts back what the last turn changed and says, in the same line,
  what it could not.
- `/rewind N` does the same for the last N turns, newest first.
- `/redo` takes the last `/undo` back.

**Put back:**

- Everything `write`, `edit` and `apply_patch` changed. Previous contents are
  saved before the tool runs, `.env` files included. A file over 10 MB is
  changed without being saved, and is named as not restorable.
- In a git repository, what each `bash` command changed (and the `elixir`
  tool, with `--elixir`). A private git snapshot is taken just before and just
  after each command, covering:
  - tracked files;
  - untracked files up to 1 MB: at most 2,000 in the whole repository, files
    in directories git tracks first, then those in untracked directories;
  - deletions, renames, `chmod +x` and symbolic links;
  - files and directories a command created. An empty directory you already
    had is kept.
- In a git repository, what the post-edit check ([Checks after
  edits](#checks-after-edits)) changed. It is snapshotted like a command and
  undone with the turn whose edits it checked.
- A command stopped with Ctrl-C, `/cancel` or its timeout. It is snapshotted
  when it stops and undone like any other. If you type `/undo` while that
  snapshot is still being taken, it says "a command you stopped is still
  being recorded"; run it again in a moment. If `lmx` itself stopped in the
  middle of a command, that command is named as not recorded.
- A file that a command and a file tool both changed in one turn goes back to
  how it was before the first of them. A generated file the agent then edited
  is deleted, and so is an ignored `.env` that a command created and the agent
  then edited.

**Named, but not put back:**

- Ignored files, and untracked files over 1 MB or past the first 2,000, that a
  command changed, created or deleted. Their contents are never saved, and an
  ignored file that only a command created is left in place.
- An ignored file a command rewrote before the agent edited it.
- Ignored directories (`node_modules/`, `_build/`) a command created or
  deleted, by name only.
- Tracked files that git keeps through a filter driver (Git LFS, git-crypt,
  `nbstripout`) and that a command changed: undo runs no filter, so their
  contents are never saved. Edits made to them with `write`, `edit` or
  `apply_patch` are put back as usual, and a file marked `-filter` is undone
  like any other.
- Files a command changed outside the working directory but inside the
  repository, when you started `lmx` in a subdirectory.
- Commands, and the post-edit check, that ran outside a git repository, in a
  directory the repository ignores, or in a repository whose `core.worktree`
  points at another directory.
- What a background command changes after the call that started it returns.
- MCP tool calls.
- Commits, branch switches, resets, stashes and pushes. `/undo` never moves
  `HEAD` or your refs back; `git reflog` shows the way back. After an agent's
  `git checkout -b x && git commit`, `/undo` leaves you on `x` with the
  reverted files as uncommitted changes.
- A file the agent edited inside an ignored directory after a command ran in
  the same turn. It is put back as the edit found it and flagged "may still
  differ from before the turn".
- In a repository with more than 2,000 entries that undo can only name
  (ignored files and directories, filter-driver files, and untracked files it
  did not save), a line says that changes to the rest are neither undone nor
  reported.

**Not recorded at all:**

- what a command changes inside an ignored directory, beyond the directory
  appearing or going;
- an empty directory a command creates;
- files outside the git repository a command ran in, such as your home
  directory;
- what a command changes inside a git submodule: a snapshot keeps only the
  commit the superproject records for it;
- what command hooks change. A post-tool hook that rewrites a file the agent
  just wrote, such as a formatter, is accounted for.

**Your own edits.** A file you save while one of the agent's commands or the
post-edit check runs is undone with it, and `/redo` takes that undo back. The
check is usually your test suite, the longest command of a turn, so that is
the likeliest moment. A file you save between the agent's commands is kept,
unless the agent changes it again later in the turn; then it goes back to how
it was before the agent's first change.

**Conflicts.** A file changed since the agent changed it is left alone and
named. `/undo --force` puts those files back too, for the turn the report was
about; `/undo` again keeps them and undoes the turn before. `/redo` treats a
file changed since the undo the same way, and `/redo --force` overwrites it,
keeping what it overwrote in the checkpoint store.

Also worth knowing:

- `/undo` itself never touches your branches, index or stash, and does not
  undo the agent's git commands either.
- `/diff` cannot show ignored files.
- Command snapshots are unreferenced objects in the repository's own
  `.git/objects`. After `git gc` prunes them, `/undo` says the snapshot is
  gone. Each post-edit check costs two of them.
- Snapshots and restores run git with a private git directory and settings
  of their own, so nothing the repository configures runs: no hook,
  `core.fsmonitor`, filter driver or submodule setting. `/diff` runs git the
  way a command does, in the session's environment and sandbox, and your own
  `git` runs whatever the repository configures. A command, sandboxed or
  not, can write `.git/config` and `.git/hooks`: after a session in a
  repository you do not trust, check both before you use git there.
- `/doctor` says what `/undo` covers in this directory: file tools and
  commands, or file tools only, and why.
- `"disabled_extensions": ["checkpoints"]` turns recording off; the post-edit
  check still runs, unrecorded. With `LMX_HOME` unset, `--config none` leaves
  `lmx` nowhere to record, and so does a `~/.lmx/config.json` it could not
  create: nothing is recorded and the post-edit check does not run. Either
  way `/undo` says that no checkpoints are recorded in this session. A
  checkpoint directory that cannot be written is reported by its path.
- `lmx run` records checkpoints too: run `lmx --resume SESSION`, then `/undo`.
- Checkpoints live in `~/.lmx/checkpoints`, private to you. They hold saved
  file contents (`.env` files included), what each undo replaced and what a
  forced redo overwrote, and they are kept until you delete them; nothing
  prunes them.

## Running commands yourself

`!npm test` (or `/shell npm test`) runs a command in the session's
environment, under the same credential policy and sandbox as the agent's
`bash`. The output is shown, and your next message carries it to the model,
marked as something you ran.

## Checks after edits

After a turn that edited files, `lmx` runs the project's own check and, if it
fails, gives the model up to two more tries to fix it. The command is
discovered, first match wins: `tests/run.sh`, a `Makefile` `test` or `check`
target, `mix test`, the `package.json` test script, `cargo test`,
`go test ./...`, `pytest -q`, then Gradle or Maven. The check is skipped when
the model already ran exactly that command, and saw it pass, after its last
edit. In a git repository, `/undo` takes back what the check changed together
with the edits it checked.

The check is a command the repository chose, so it goes through the same
permission policy as the agent's commands. With permissions off it runs
unasked; with `--permission-mode ask` or `accept_edits` it asks first, and a
rule such as `"Bash(make test)"` in `allow` lets it through. A refused check
is not a failure: the turn simply ends. `/verify` shows whether the check is
on and how the last one went; `/verify off` pauses it for the session,
`"verify": {"command": "make lint test"}` names the command, and
`"verify": false` turns it off.

## MCP servers

Your own servers go in `"mcp_servers"` in `~/.lmx/config.json`.
`lmx mcp import claude` copies your user-scope servers from Claude Code
(servers you added to one project there stay behind, and it names them), and
`lmx mcp import codex` copies Codex's. A repository's `.mcp.json` waits for
you: the first time, a panel lists each server's command or URL and the
variables it reads, and asks. The answer is remembered until the file
changes. `/mcp` shows each server's state and reconnects one, signing in
where it needs OAuth; tokens are kept in `~/.lmx/mcp-credentials.json`,
readable only by you. `/prompts` lists the prompts servers offer as commands.

## Scripts and CI

```sh
lmx run "Summarize this repository without changing files" > summary.md
git diff | lmx run "Review this change:" -
lmx run --output-format json "…" | jq .text
```

Only the final answer goes to standard output. Standard error carries a
start line (session id, name and model), notices, a usage line and any
errors. The exit status says what happened: 0 answered, 2 usage,
3 credentials, 4 a limit, 5 cancelled, 6 provider, 1 anything else.
`--output-format stream-json` streams events, one per line. `lmx run` loads
the same workspace as the terminal UI; `--bare` leaves it out. A repository's
`.mcp.json` servers start only if already trusted (`lmx mcp trust --yes`) or
with `--project-mcp`. A call that would ask for approval is refused, since
nobody is there to answer.

From a source checkout, run `mise exec -- mix compile` once before
redirecting `mise exec -- mix lmx run …`, because Mix prints compile progress
on standard output.

## Coming back

When you leave, `lmx` prints the line that resumes the session. `lmx -c`
resumes the newest session that ran in this directory, and `/resume` lists
them, most recently active first (`/resume all` for every directory). Ctrl-R
searches what you have typed, across sessions. `/export` writes the
conversation as Markdown, and `/doctor` summarizes the model, key, limits, MCP
servers, permissions, what `/undo` covers here and whether a sandbox is
available, when something seems off.

## Next steps

Use the [CLI reference](cli.md) for commands, keys, output formats and limits.
Save defaults with [Configuration](configuration.md), or follow
[Customizing Lemieux](customization.md) to adapt instructions, tools and
policy.
