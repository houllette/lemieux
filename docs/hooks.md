# Hooks

A **hook** is your own code that runs at a named point in an agent session:
before a tool runs, after it returns, when you submit a prompt, when the
agent wants to stop. Hooks are for what a prompt cannot reliably enforce:
approving or refusing a tool call, writing an audit record, adding live
context, or refusing to let the agent stop before an external check passes.

Lemieux supports both sides of the same seam:

- An application that embeds Lemieux (a **host**) passes Elixir functions in
  the session's `:hooks` option.
- `lmx --hooks FILE`, or the `"hooks"` object in `~/.lmx/config.json`, loads
  external commands that receive JSON on stdin. The file may use Lemieux's
  versioned format or be a Claude Code settings file (`.claude/settings.json`)
  passed as it is; see [Claude Code settings files](#claude-code-settings-files).
  A plugin you selected brings its own hooks the same way.

`lmx` never runs hooks just because a file contains them. A checkout's
`.claude/settings.json`, and your own `~/.claude/settings.json`, run only
when you pass one with `--hooks`.

The shipped permission policy, `Lemieux.Extensions.Permissions`, is built on
the same `before_tool_call` seam; see [Permission modes](#permission-modes).

Hooks are host policy, not session configuration. They are neither written to
the transcript nor restored on resume. A conversation moved to a different
host gets that host's policy.

## Command hook file

A command file is a versioned JSON object. An event contains a list of direct
commands or matcher groups:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "matcher": "bash|edit",
        "hooks": [
          {
            "type": "command",
            "name": "repository policy",
            "command": "./scripts/agent-policy",
            "timeout": 30000
          }
        ]
      }
    ],
    "postToolUse": [
      {"command": "./scripts/audit-agent-tool"}
    ],
    "agentStop": [
      {"command": "./scripts/verify-agent-work"}
    ]
  }
}
```

Each command may set `name`, a millisecond `timeout` (default `60000`; the
`timeoutMs` spelling is also accepted), `cwd` (absolute or relative to the
session directory), an `env` object, and `args` for
[exec form](#shell-form-and-exec-form). `type` defaults to `command`; no
other execution type exists.

`"hooks"` in `~/.lmx/config.json` holds either a whole hooks document, in
either format, or a bare events object (`{"preToolUse": [...]}`). A bare
events object is always read as Lemieux's format, even when it uses Claude
Code's event names: its timeouts are milliseconds and its commands see
Lemieux's names. To use Claude Code's format there, nest it as a settings
file does: `"hooks": {"hooks": {"PreToolUse": [...]}}`. The config file's
hooks apply beside `--hooks`, not instead of it.

`matcher` is most useful on tool events, where it sees the tool name. Empty,
missing, and `*` match everything. Ordinary names use exact `|`-separated
alternatives; a value with regular-expression characters is a regex. Both
ignore case, and a tool is matched by its own name and by the Claude Code
names it answers to: `Bash` matches `bash`, `Edit|Write` matches `edit`,
`write` and `apply_patch`, `Read`, `Grep` and `Glob` match their Lemieux
namesakes, `WebFetch` matches `web_fetch`, `Task` the scout's `delegate`,
`TodoWrite` the `todo` tool, and `mcp__github__.*` an MCP server's tools.

`lmx` does not warn when a matcher names no tool, so a typo in a matcher
makes a guard that silently never runs. Before you rely on a new guard, make
it refuse one call. A host can check for itself:
`Lemieux.Hooks.unmatched/2` lists the plain-name matchers that name no tool
a session has. It does not judge a regular expression or an MCP name, which
may match a tool that arrives later.

The canonical event names are:

| Event | When it runs | May control the loop |
| --- | --- | --- |
| `sessionStart` | A new or resumed session is ready | No |
| `attention` | A call parks, or the final parked call releases | No |
| `userPromptSubmitted` | Before a prompt is persisted or sent | Deny or rewrite the prompt |
| `preToolUse` | Before any local or MCP tool runs | Deny or rewrite tool input |
| `postToolUse` | After a tool returns success or failure | No |
| `agentStop` | Before the model's final stop makes the session idle | Deny with feedback to continue |
| `errorOccurred` | A provider error arrives | No |
| `sessionEnd` | The host terminates the session process | No |

`lmx` stops its session itself — after `lmx run` prints its answer and when
the terminal UI quits — so `sessionEnd` runs at the end of every command; a
host that only halts the VM never reaches it.

Common Claude Code and Gemini CLI spellings are accepted as aliases:
`SessionStart` for `sessionStart`; `Notification` for `attention`;
`UserPromptSubmit` and `BeforeAgent` for `userPromptSubmitted`; `PreToolUse`
and `BeforeTool` for `preToolUse`; `PostToolUse` and `AfterTool` for
`postToolUse`; `Stop` and `AfterAgent` for `agentStop`; and `SessionEnd` for
`sessionEnd`. In a Lemieux file the command still receives Lemieux's
canonical event name in its input.

### Shell form and exec form

A command without `args` is **shell form**: `command` is a script, run by
`bash` (or `sh` where there is no `bash`), with the JSON input on stdin.

A command with `args` is **exec form**, in either file format: `command` is
the program, a path or a name looked up on `PATH`, and each element of
`args` is one argument, exactly as written. No shell reads either, so a space
or a `$` in an argument is passed as it is. The JSON input still arrives on
stdin, and the program runs in the session directory (or the command's own
`cwd`), so a relative path is relative to it. In a Lemieux file:

```json
{
  "type": "command",
  "command": "python3",
  "args": ["scripts/check.py", "--strict"]
}
```

With no shell to expand them, `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_PLUGIN_ROOT}`
and `${CLAUDE_PLUGIN_DATA}` are replaced with their values wherever they
appear in `command` and `args`, but only in a command that has the variable
([What a command inherits](#what-a-command-inherits)): a command from a
Claude Code settings file has `CLAUDE_PROJECT_DIR`, a plugin's hooks have
all three, and a command's own `env` can set them. Anywhere else the text
stays as written. This is the exec form of a Claude Code project hook, in
`.claude/settings.json`:

```json
{
  "type": "command",
  "command": "python3",
  "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/check.py", "--strict"]
}
```

A program name with a space and no slash beside `args`, such as
`"node script.js"`, loads with a warning, because the extra words belong in
`args`. A program whose name starts with `-` is not run; like any hook that
fails to start, its action goes ahead.

## Command protocol

Every command receives one JSON object on stdin. Every event includes:

```json
{
  "session_id": "01M...",
  "cwd": "/checkout",
  "hook_event_name": "preToolUse",
  "timestamp": "2026-08-15T02:30:00Z"
}
```

Event-specific fields are:

- `sessionStart`: `source`, either `startup` or `resume`.
- `attention`: `state`, either `waiting` or `working`; waiting also includes
  `call_id` and `kind` (`approval` or `question`).
- `userPromptSubmitted`: `prompt`.
- `preToolUse`: `tool_name`, `tool_input`, and `tool_use_id`.
- `postToolUse`: the tool fields plus `tool_result`, containing `output` and
  `error`.
- `agentStop`: `stop_reason` and `stop_hook_active`. The latter is `true` on
  a retry caused by a previous stop hook, so the hook can avoid an endless
  loop.
- `errorOccurred`: `error`.
- `sessionEnd`: `reason`.

Exit `0` means success. Empty stdout allows the action. JSON stdout may make a
structured decision:

```json
{"decision":"deny","reason":"production writes need approval"}
```

For `preToolUse`, the decisions are:

| Output | Meaning |
| --- | --- |
| `"decision": "deny"` or `"block"`, with `reason` | Refuse the call; the model reads the reason |
| `"permissionDecision": "deny"`, top level or in `hookSpecificOutput`, with `permissionDecisionReason` | Refuse the call |
| `"permissionDecision": "ask"` | Park the call for a person, like an Elixir hook returning `:pending` |
| `"permissionDecision": "allow"`, or `"decision": "approve"` | Approve the call explicitly |
| `"continue": false`, with `stopReason` | Refuse the call |
| Nothing of the above | No objection; later hooks decide |

Deny wins over everything else in the same output. An explicit approval is
different from no objection: the hooks after it see `context.approved_by`,
and the shipped permission policy does not ask about a call a hook already
approved. Deny rules and read-only mode still apply.

For `preToolUse`, a successful hook may also replace the arguments:

```json
{"updated_input":{"path":"safe.txt"}}
```

For `userPromptSubmitted`, use `updated_prompt`. Lemieux also understands the
portable `hookSpecificOutput.updatedInput` and
`hookSpecificOutput.additionalContext` fields used by other hook systems. An
`updatedInput` written with Claude's field names (`file_path`, `old_string`,
`new_string`, `timeout`, `run_in_background`) reaches the tool under its own
names.

A `postToolUse` hook cannot undo a call that already ran, so a block there is
feedback instead: exit `2` (its stderr), `"decision": "block"` with a
`reason`, and `hookSpecificOutput.additionalContext` are appended to the tool
result the model reads next, under a `[hook]` marker. An Elixir
`after_tool_call` callback does the same by returning `{:feedback, text}`.

Exit `2` blocks without any JSON. The denial reason is the `reason` of any
JSON object on stdout, then stderr, then stdout, then a generic message
naming the hook. On `agentStop`, a denial is appended as user feedback and
starts another model turn; the session's `max_turns` remains the hard upper
bound. Exit statuses other than `0` and `2`, invalid JSON, startup failures,
and timeouts allow the action, with a warning
([Where warnings go](#where-warnings-go)). A policy script that must block
must therefore exit `2` or return a structured deny rather than relying on
an ordinary failure status.

Only stdout is parsed as JSON, and only on exit `0`. Stderr is available for
logs and blocking reasons without corrupting the protocol.

### Where warnings go

A hook that fails lets its action go ahead, and in `lmx` nothing on screen
says so:

- What goes wrong while a hook runs (it could not start, timed out, exited
  with a status other than `0` or `2`, or printed invalid JSON), and a
  `systemMessage` in its output, are logged as warnings. `lmx` writes
  warnings only when `LMX_LOG_LEVEL` is `warning`, `info` or `debug`: then
  to `logs/lmx.log` in its state directory (`~/.lmx/logs/lmx.log`) and to
  standard error, except over the terminal UI's screen
  ([Logs](cli.md#logs)).
- What reading a file warned about (a skipped event or hook type, a program
  name whose other words belong in `args`, `"disableAllHooks"`) is recorded
  in the session's harness snapshot, under the hooks extension's
  `"warnings"`; `lmx log SESSION --jsonl` prints it. `lmx explain` does not
  show it.

So test every guard once: make it refuse a call it should refuse.

### What a command inherits

A command runs in the session's working directory (or its own `cwd`), with
the launching user's permissions, like the `bash` tool. It starts from the
environment the host says a person's commands get
(`Lemieux.Environment.Inherited`): under the installed `lmx`, the one you
started `lmx` in, with your own `PATH`, and none of the variables the
release sets for its own runtime ([What commands
inherit](configuration.md#what-commands-inherit)). Its environment then
follows the session's credential policy: a tool hook inherits exactly what
the environment the tool runs in would give a command
(`Lemieux.Environment.credentials/1`), so a session whose `bash` cannot read
`OPENAI_API_KEY` does not hand it to a hook script instead. `lmx` withholds
every variable whose name contains `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or
`PASSWD`, except the names in `"credential_allowlist"`. The `:credentials`
option of `Lemieux.Hooks.Config.load/2` sets one policy for every command in
a file.

On top of that:

- A command from a Claude Code settings file gets `CLAUDE_PROJECT_DIR`, the
  directory the session started in. Claude Code's project hooks are written
  as `"${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh"`, and work as written.
- A plugin's hooks also get `CLAUDE_PLUGIN_ROOT`, the plugin's directory, and
  `CLAUDE_PLUGIN_DATA`, its persistent data directory
  (`~/.lmx/plugin-data/<id>`, created readable only by you before the first
  command that is told about it runs).
- The command's own `env` comes last and wins, including over a withheld
  variable: a hook file that sets `GITHUB_TOKEN` for its own script has said
  that this script may have it.

The JSON a hook receives on stdin is written to a fresh directory only the
launching user can open, and removed when the hook exits.

### Timeouts

A command that runs past its timeout is stopped together with everything it
started: its whole process group is killed, with the `kill` program, or the
shell's own `kill` where an image ships none, or `taskkill /T` on Windows.
The hook's action then proceeds, with a logged warning.

### Windows

On Windows, hooks run in Git for Windows' bash, the same one the `bash` tool
uses: at Git's standard install locations (under Program Files, or your own
`Programs` folder), then in the installation `git --exec-path` reports, then
any other `bash` or `sh` on `PATH`. WSL's `bash.exe` is never used, because
it runs the hook inside a Linux distribution that sees neither this
environment nor these paths. Without Git Bash no hook can start: each one
logs a warning that names what to install, and its action goes ahead. The
Windows build of `lmx` is experimental, and this path has not been qualified
on a Windows machine.

## Elixir callbacks

Callbacks remain the direct embedding API:

```elixir
hooks: [
  session_start: fn %{source: source}, context -> audit_start(source, context) end,
  attention: fn %{state: state} = payload, context -> notify(state, payload, context) end,
  user_prompt: fn prompt, context -> validate_prompt(prompt, context) end,
  prepare_next_turn: &MyApp.Context.prepare_turn/2,
  before_tool_call: &MyApp.Policy.before_tool/2,
  after_tool_call: &MyApp.Audit.after_tool/3,
  stop: &MyApp.Verifier.before_stop/2,
  error: &MyApp.Audit.error/2,
  session_end: &MyApp.Audit.session_end/2
]
```

`user_prompt` returns `:allow`, `{:deny, reason}`, or
`{:rewrite, new_prompt}`. `prepare_next_turn` receives the complete
provider-neutral `Lemieux.Request` and its context immediately before the
budget check and dispatch; it returns `{:ok, %Lemieux.Request{}}` or
`{:deny, reason}`. It has no command-hook event, so it is Elixir-only.
`before_tool_call` has the existing tool decision contract: `:allow`,
`{:deny, reason}`, `{:rewrite, arguments}`, or `:pending`. `:pending` parks
the call in the session and puts the decision in somebody else's hands: the
session writes an `approval` entry, emits `{:tool_approval, call}` to its
subscribers, and waits for `Lemieux.Session.resolve_tool/3` or its approval
timeout (five minutes by default; `:approval_timeout`), which refuses the
call with a reason the model reads. `{:pending, details}` does the same with
`details` merged into the call subscribers are shown (the call's own `id`,
`name` and `arguments` cannot be overridden). The `lmx` terminal UI shows a
parked call and takes the answer at the keyboard — a card naming the tool
and its arguments, answered with `y`, `n [reason]`, `/approve` or `/deny`
([CLI](cli.md#slash-commands),
[Terminal UI](terminal-ui.md#approvals-and-elicitation))
— and a host of your own does the same by folding the event or the entry
through `Lemieux.Conversation.event/2` and calling `resolve_tool/3`. Whichever
host answers first, the session records one decision and every host clears
its waiting state on that entry.
`stop` returns `:allow` or `{:deny, feedback}`. It is a decision hook, not an
observer: it is not wrapped by the observer rescue path, and any other return
is a hook failure. Do not use `stop` as a notification callback. Observer
callback return values are ignored.

Prompt and stop callbacks run in supervised tasks. A slow policy does not stop
the session answering snapshots, cancellation, or other calls. Tool callbacks
run in the task for that tool call. Observer callbacks are best effort;
accounting that must survive a process crash should still read transcript
entries rather than count callback invocations.

Attention is session-level. Every newly parked call emits `waiting`; `working`
is emitted only when the final pending call releases, so resolving one of
several approvals cannot clear a badge while another decision still waits.

## Request preparation and retries

An embedded host's `prepare_next_turn` function receives `(request, context)`
before every attempted dispatch, including automatic provider retries. It
must still approve the current request on re-entry. `context.retry` is `nil`
for an ordinary request; on a retry it contains the string-keyed fields
`"attempt"`, `"after_request_id"`, `"category"`, `"reason"`, and `"delay_ms"`.
The same note is written on the request entry if dispatch succeeds.

Count logical iterations only when `context.retry` is nil. Count dispatched
provider attempts from request entries, since preparation can be denied or
stopped by a budget. Retries consume `max_requests` and `max_turns` like other
provider attempts. An exhausted limit refuses the retry immediately and
preserves the original typed provider error and durable error entry.

Hosts whose durable scheduler owns retries should set `provider_retry: false`
on the session. Setting a provider's own `max_retries: 0` controls its internal
transport retries and does not disable the session policy.

## Claude Code settings files

A document with a `"hooks"` object and no `"version"` is read as a Claude
Code settings file, so `lmx --hooks .claude/settings.json` reads it as it is.
A versioned file that sets `"dialect": "claude"` is read the same way.
Reading it that way changes what the commands see, because that is what such
a file means:

- A command's `"timeout"` is in **seconds**, as Claude Code documents it
  (`"timeoutMs"` is milliseconds in either format).
- Its commands receive what a Claude hook script expects: Claude's event
  names (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`,
  `SessionStart`, `SessionEnd`, `Notification` with a `message`), Claude's
  tool names (`Bash`, `Edit`, `mcp__server__tool`), Claude's field names in
  `tool_input` beside Lemieux's (`file_path` beside `path`, `old_string` and
  `new_string`), and a `tool_response` on `PostToolUse`. Some of these
  differ from what Claude Code sends; see
  [What is not supported yet](#what-is-not-supported-yet).
- They get `CLAUDE_PROJECT_DIR` in their environment, and a plugin's also get
  `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`
  ([What a command inherits](#what-a-command-inherits)).
- Plain text a `UserPromptSubmit` hook prints, and its `additionalContext`,
  are added to the prompt as context, as Claude Code does. Plain text from
  any other event is not reported as invalid JSON.
- An event or hook type with no Lemieux equivalent is skipped with a warning
  ([Where warnings go](#where-warnings-go)) instead of failing the file. A
  versioned Lemieux file still fails on an unknown event.

Other settings keys are ignored here, and `"disableAllHooks": true` loads
nothing. A host that can show warnings to a person reads the file with
`Lemieux.Hooks.Config.load/2`, which returns them;
`Lemieux.Extensions.Hooks` records them under `"warnings"` in its provenance.
`Lemieux.Hooks.Config.load/2` also takes a bare events object — what a
personal configuration file holds under `"hooks"` — in either dialect.

### SessionStart output

What a Claude Code `SessionStart` hook prints is context for the model, as
in Claude Code. Its plain stdout and its `hookSpecificOutput.additionalContext`
are put in front of the session's first prompt, inside
`<session-start-hook-context>` … `</session-start-hook-context>`, and saved in
the transcript as part of that message. This happens at startup and again
when a session is resumed.

The first prompt waits for those hooks, at most the sum of their timeouts
plus five seconds; a hook that hangs costs the prompt its context, not the
prompt. A prompt that a `UserPromptSubmit` hook denies leaves the context for
the next one. A delegated subagent's session does not run these hooks:
Claude Code fires `SubagentStart` there, which Lemieux does not have. A
`sessionStart` command in Lemieux's own format still only observes.

### What is not supported yet

These parts of Claude Code's hook format are ignored or behave differently.
Check this list before relying on a hook as a guard: a script that compares
`file_path` with an absolute path finds no match and lets the call through,
and one that reads `tool_response.filePath` reads nothing.

| Claude Code | In Lemieux |
| --- | --- |
| Hooks in your `~/.claude/settings.json` run in every project | Not read. Pass the file with `--hooks`, or copy its hooks into `~/.lmx/config.json` as `"hooks": {"hooks": {…}}` |
| A repository's `.claude/settings.json` hooks run when you open it | Never run on their own, and `lmx` says so in a startup notice; pass the file with `--hooks` |
| `tool_input.file_path` is an absolute path | It is the path the model wrote, often relative to the session directory that `cwd` in the input names. Resolve it against `cwd` before comparing |
| `tool_response` holds the tool's own fields: `stdout` and `stderr` for Bash, `filePath` and `success` for Write | Always `{"output": …, "error": true or false}`, for every tool |
| `"continue": false` stops the agent | Refuses the call on `PreToolUse` and the prompt on `UserPromptSubmit`, and the agent carries on; ignored on other events |
| The `if`, `async`, `asyncRewake`, `once` and `shell` fields (PowerShell included) | Ignored. A hook scoped with `"if": "Bash(git *)"` runs on every `Bash` call, and every command runs in bash |
| Comma-separated matchers such as `Edit, Write` | Do not match. Separate alternatives with a vertical bar, as in the [command hook file](#command-hook-file) example |
| JSON output on any exit status | Read only on exit `0`. Exit `2` blocks, and only a `reason` is read from its output; any other status allows the action, with a logged warning |
| `transcript_path`, `permission_mode` and `last_assistant_message` in the input | Not sent |
| The 600-second default timeout | 60 seconds; set `"timeout"` for longer |
| `SubagentStart`, `SubagentStop`, `PreCompact`, `PermissionRequest` and other events | Skipped, with a warning ([Where warnings go](#where-warnings-go)) |
| `prompt`, `agent`, `http` and `mcp_tool` hook types | Skipped, with a warning |
| `SessionStart` with source `clear` or `compact` | Never fires; only `startup` and `resume` |
| `systemMessage` shown to the person | Logged as a warning ([Where warnings go](#where-warnings-go)) |
| Plugin `userConfig` and `CLAUDE_PLUGIN_OPTION_*` variables | Not supported |

## Permission modes

`Lemieux.Extensions.Permissions` is the shipped approval policy. It is off
unless a host applies it, and asks before the agent changes things the way
Claude Code and Codex do.

**`lmx` starts with it off:** every tool call runs without asking (full
auto), and the terminal UI says so when it starts. `--permission-mode MODE`, or
`"permissions": {"mode": MODE}` in `~/.lmx/config.json`, turns it on;
`--permission-mode ask` is the usual choice. In the terminal UI, Shift-Tab
then steps through the modes. Its modes:

| Mode | What runs without asking |
| --- | --- |
| `ask` | Reading, the todo list, `ask_user`, and whatever an allow rule names |
| `accept_edits` | The above, plus file edits in the session directory |
| `auto` | The above, plus commands, when the session runs in a sandbox environment (`Lemieux.Environment.Sandbox`, `lmx --sandbox`); otherwise like `accept_edits` |
| `full_auto` | Everything except what a deny rule names |
| `read_only` | Reading only; anything that changes things is refused unless a rule names it |

Claude Code's mode names are accepted too: `default` means `ask`,
`acceptEdits` means `accept_edits`, `bypassPermissions` means `full_auto`
and `plan` means `read_only`.

Rules use Claude Code's syntax: `Bash(npm run test:*)`, `Edit(src/**)`,
`Read(.env)`, `WebFetch(domain:hex.pm)`, `mcp__github`. Deny rules win in
every mode, ask rules come next, allow rules after. A prefix rule never
approves a compound command whose other parts it does not name —
`Bash(git status:*)` does not approve `git status && curl … | sh` — and never
approves command substitution or a redirection into a file. Deny rules are
checked against every piece of a command, including those inside `$(…)` and
behind `sudo`. This is a reading of shell syntax for a policy that asks when
unsure, not a sandbox; pair `auto` mode with a sandbox environment for a
boundary the operating system enforces.

The project check `lmx` runs after edits ([Verify after
changes](workflows.md#verify-after-changes)) goes through the same policy, as
the `bash` call that would run it: `Bash(make test)` in `allow` lets it run
unasked, and a `Bash` deny rule refuses it.

A question parks the call as `{:pending, %{permission: details}}`, so the
call the TUI receives carries `permission["suggestions"]`: the rule an
"always allow" answer would remember (`Bash(mix test:*)`) or the mode it
would switch to. `Lemieux.Extensions.Permissions.remember/2` writes a rule to
the handle's store, `set_mode/2` and `cycle/1` change the mode of every
session using the handle, and `resolve_tool/3` answers the call itself. A
host with nobody to ask sets `non_interactive: :deny` (or `:allow`); in
`lmx run`, a call that would ask is refused unless `"non_interactive":
"allow"` in `"permissions"` says otherwise.

## Trust boundary

A command hook is arbitrary code with the launching user's filesystem access
and OS permissions. Lemieux does not auto-discover a `.lmx/hooks.json` or
reuse another agent's project settings, because opening an untrusted checkout
must not silently execute code before a person asks the agent to do anything.
Pass `--hooks PATH` explicitly, select a plugin, or let an embedding host load
command hooks after applying its own trust policy. Hooks run beside
`--sandbox`, not inside it. The
[trust model](../SECURITY.md#what-lmx-trusts-by-default) puts hooks beside
`lmx`'s other defaults.
