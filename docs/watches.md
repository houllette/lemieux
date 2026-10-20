# Background tasks and external runs

Open **Tasks** with **Shift+Up**, or click the **Tasks** badge on the message box.
Background Bash commands appear automatically. The view combines **Agent**
assignments, local **Command** processes and registered **External run** watches.
It grows upward from the message box to fit its content, leaving the composer
and part of the primary transcript visible. Longer lists and output scroll
inside the tray. **Active** and **History** separate ongoing work
from completed results. Each activity keeps one row through status changes,
with its command, elapsed time and output together. Pausing and resuming tracking
keeps its observation history inside that activity's details.
Background commands receive collision-safe hockey-player names. The model supplies
a one-line purpose summary when launching a task; chat shows the name and summary
instead of shell source or internal task IDs. The tray shows a command preview
above live output; **Expand command** opens the complete, scrollable shell source.
Task controls accept the player name as well as the internal ID, while keeping
the same session ownership checks.
There is no task-management slash command to learn, and opening the view does
not consume a model request. The message draft stays intact. Empty views keep
their last known state during refreshes. The shortcut hint stays on the composer
badge; completion cards contain the outcome, duration and purpose. F6 remains
an alternate binding for terminals that cannot report Shift+Up.

Use [durable jobs](jobs.md) when the assignment itself must run independently.
The task view observes existing work; adding an external watch never starts or
restarts that work.

## Native controls

| Control | What it does |
| --- | --- |
| Up / Down | Select a task |
| `1` / `2`, or Active / History | Switch between ongoing work and retained results |
| Enter / Tab | Focus output; Tab switches between the list and inspector, with a highlighted border and explicit focus label |
| Page Up / Page Down, or the mouse wheel | Scroll selected output |
| End | Follow the newest output again |
| Expand command / Instructions (`v`) | Toggle between full shell source or agent instructions and output; press `v` again to return (`l` also shows output) |
| Steer agent (`t`) | Write an instruction in a separate editor; Ctrl-Enter queues it for the next model request |
| Cancel agent / Cancel writer batch (`c`) | Stop a delegate, or all writers in the selected batch, under the current host policy |
| Cancel command (`c`) | Confirm cancellation of a local command; pending continuation is revoked first |
| Pause tracking (`s`) | Pause observation while the command or external run continues |
| Resume tracking (`w`) | Resume observation of a running command or paused external run |
| Auto-resume (`f`) | Choose automatic continuation or notification only; automatic is the default |
| Clear logs (`x`) | Confirm clearing retained output after delivery; transcript evidence stays on record |
| Open run (`o`) | Open the external run's link |
| Add watch (`a`) | Open native fields for an existing external run |
| Shift+Up / Esc | Close the view and return to the draft |

The visible controls also accept mouse clicks. Destructive actions require a
confirmation. External sources expose observation controls; they do not expose
remote cancellation. The selected command's live preview retains the newest
32 KB, so a chatty command continues showing progress. Commands retain bounded
output internally, and external results retain at most 8 KB of logs.

The inspector separates the task name and colored status, purpose, muted
metadata, source preview and output. Completed output is labelled **Result**.
Command source keeps literal whitespace; agent answers retain paragraph breaks,
headings and inline emphasis. Warning, error and success log lines have distinct
styles. Focus labels and bold borders also work in the monochrome theme.

Local commands belong to their runtime and session. Closing that runtime ends
those processes; reopening a transcript cannot recreate an operating-system
process. Use an external durable job for work that must survive closing `lmx`.

## Delegates and isolated writers

The same Tasks view shows read-only delegates and isolated writers even when
they have no background commands. Their commands nest beneath the owning agent.
Select an agent to inspect its brief, activity and result; live delegates also
show their own token and context usage. Commands show process output rather
than a separate model context. Delegate steering preserves its original scope,
permissions and budget. Writer cancellation explicitly applies to the whole
batch; artifact integration still uses the writer review workflow.

Inspect output or cancel a command directly. The bounded assignment manages completion: it stays open, waits
without model polling, then receives one batch of command results under its
remaining request, turn, cost and time limits. Human cancellation revokes that
continuation. These rows do not offer a separate Auto-resume toggle.
Completed agent results remain in History after resume, while live controls
require the current owning session and the host's current authorization.

The default scout has sandboxed read-only `bash` for inline analysis scripts,
including `background: true`. A writer factory can explicitly supply the same
tool without granting unrestricted commands. See [delegates](subagents.md#background-analysis)
and [writers](writers.md#results-and-review). These capabilities use the native
runtime; writers still require their existing host opt-in and isolation policy.
Bounded [A2A peer tasks](a2a.md) and [durable jobs](jobs.md) use the same
completion lifecycle for background work started by their host-selected tools.
Remote data-export policies keep their existing command restrictions.

## Observe an external run

In **Tasks → Add watch**, select a source, fill its fields and choose **Create
watch**. Tab moves between fields; Left / Right chooses a source, Space toggles
the continuation checkbox, and Enter on Create submits. Ctrl-Enter submits from
any field. Escape returns to the task list.

GitHub Actions needs `owner/repo`, an existing numeric run ID and the full
40-character commit SHA. The host needs `gh` installed and signed in. Status
responses must match all three identity fields. Completion includes the run
link, outcome and bounded failed logs where available. Authentication failure,
missing status and deadline expiry have distinct outcomes.

Configured custom sources take an existing run ID. Their reader command is
selected by the host, never entered through the task view or supplied by the
model.

## Notifications, defaults and recovery

Results already collected by a successful model tool call are acknowledged in
the transcript. They stay available in Tasks history and do not produce another
completion card or answer. Opening the tray alone does not acknowledge a result
to the model, so unattended completions still resume the existing task.

Turn dividers show **tokens this turn**: cumulative usage across that turn's
model requests, including context sent again on each request. The context meter
shows the latest request's measured context instead. A completion starts a new
turn with its own usage counter; a smaller turn total does not mean context was
discarded. Actual compaction has its own visible summary notice.

Native background observation is enabled by default in CLI sessions, including
restricted profiles and hermetic `--config none` sessions. Hermetic sessions keep
monitoring state in memory and create no personal watch journal. Restricted
profiles retain their selected model tools. The Tasks view can inspect and
cancel owned local commands even when monitoring is disabled.

**Automatic continuation** is the default. Tracking requires no separate
approval; the command itself still passes the session's normal permission and
sandbox checks before it starts. Completion waits for the session to become idle,
records its evidence and sends the normal terminal notification. An unfinished
plan yields after an automatically tracked background start, so waiting does
not spend requests nudging the model.

Nearby command completions are collected into one result update and one
continuation. Each named result has its own outcome, elapsed time and summary,
with full command and logs available in the tray. A durable batch receipt covers
each component, including recovery after only some journal acknowledgements were saved.
Current prompt hooks, tool approvals,
sandboxing and remaining turn, request and cost allowances still apply. External logs
are labelled as data and cannot expand file references into reads. Stopping
observation or cancelling a command revokes an undelivered continuation.
Authentication failures and deadline expiry notify without inference.

Background launches are grouped under **Background tasks** in the chat, with
one command entry each. Routine watch registration adds no duplicate chat receipt.
Completion names the command or external run; output stays in the tray.

Ordinary configured sessions also expose the `watch` tool to the model. Set
`"watches":{"follow_up":false}` for notification only by default, or turn off
**Auto-resume** on an individual task. Explicit session ask/deny rules still
apply to the watch tool. Human choices apply to the selected watch;
historical records never restore general permission to continue. The model
reuses an automatically registered background observation instead of producing
duplicate completion notifications.

Set `"watches":false`, or put `"watches"` in `disabled_extensions`, to disable
automatic observation and external watch registration. Process inspection and
cancellation remain available in the native task view.

Configured sessions keep records under the personal state directory's
`watches/SESSION_ID`. Reopening the original session re-observes pending external
runs and delivers recorded results. Monitoring pauses while no `lmx` runtime
owns the session; the original deadline continues to elapse. Transcript receipts
prevent duplicate follow-ups. A crash after recording a receipt but before
dispatch leaves reviewable evidence without automatically replaying inference.

Each session retains at most 256 watch records and runs at most four readers
concurrently. Poll intervals back off from one to sixty seconds; source rate
limits can defer checks longer within the deadline. External watches default to
one hour, with up to thirty days available. Automatically tracked commands use
the command's configured lifetime. Delivered watch logs expire after one day,
or can be cleared in Tasks; small receipts remain. Completed local commands
retain output for one hour unless cleared earlier. A session and its delegates
admit at most 256 retained commands together; a full tree refuses another
command before execution until retention frees a slot. Isolated writer sessions
have their own command allowance.

## Custom status readers

Personal configuration can name up to sixteen fixed observation commands:

```json
{"watches":{"sources":{"deployment":"/opt/bin/deployment-status"}}}
```

The deployment source then appears in **Add watch**. Its reader receives inert
target JSON in `LMX_WATCH_TARGET`, runs through the session's environment with
credential scrubbing and confinement, and inspects only the original activity.
Target values are never interpolated into shell code. Print one JSON object and
exit zero:

```json
{"state":"pending","summary":"Rolling out"}
```

On completion use `{"state":"done","outcome":"success","url":"https://example.test/deployments/42","logs":"Ready"}`.
Rate limits use `{"state":"retry","retry_after_ms":30000,"summary":"Rate limited"}`.
Errors use `{"state":"error","category":"authentication","summary":"Login expired"}`;
other categories are `unavailable` and `failed`. Failed readers, timeouts,
oversized output and invalid status are reported explicitly.

## Embedding

`Lemieux.Extensions.Watches` equips host-selected monitoring. Its
`auto_background: true` option wraps the existing Bash tool to register starts;
`equip_tool: false` preserves a restricted tool catalog. Adding Lemieux starts
nothing. The embedding host mounts `Lemieux.Extensions.Watches.Server` with its
session, task supervisor, sources and journal. `journal: nil` explicitly selects
volatile observation; a filesystem or custom `Lemieux.Jobs.Journal` supplies
persistence. Hosts retain lifecycle, credentials, storage and continuation policy.
