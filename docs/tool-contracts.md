# Governed tool contracts

A **tool** is something the model can call: read a file, run a command,
search the web. Lemieux ships four in `Lemieux.Tools.default/0` — `read`,
`write`, `edit` and `bash` — and a host (`lmx`, or an application that
embeds Lemieux) replaces or extends them through `:tools`. `lmx` adds more
through its extensions, such as `grep`, `glob`, `apply_patch`, the `todo`
plan and the `delegate` scout
([Extensions](extensions.md#what-lmx-ships-and-which-mode-applies-which)).

Tools come from two places: Elixir modules running in the host's VM, which
the host trusts, and the tools of [MCP servers](mcp.md). Both go through one
contract, described here: how to write a tool, the descriptor that says what
it may do, how its results are bounded and recorded, how it runs, and how the
files it changes are checkpointed so they can be put back. The opt-in
`elixir` tool evaluates code in a separate node; it is a tool like any
other, not the way to extend Lemieux.

## Writing a tool: the shortest path

A tool is four callbacks and nothing else is required:

```elixir
defmodule MyApp.Tools.TicketRead do
  @behaviour Lemieux.Tool

  @impl Lemieux.Tool
  def name, do: "ticket_read"

  @impl Lemieux.Tool
  def description, do: "Read one ticket by id."

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string"}},
      "required" => ["id"]
    }
  end

  @impl Lemieux.Tool
  def run(%{"id" => id}, _context), do: {:ok, MyApp.Tickets.render(id)}
end
```

Everything else has a conservative default: the tool runs alone in its wave,
counts as able to write, needs whatever approval the host's policy decides,
and runs under the session's `tool_timeout_ms`. Say more only when it is true,
and say it once, in `metadata/0`:

```elixir
@impl Lemieux.Tool
def metadata do
  %{
    effects: %{class: "read"},                      # read-only (A2A, scouts)
    runtime: %{concurrency: %{class: "parallel"}},  # may share its wave
    policy: %{approval: "never"}                    # nothing to ask about
  }
end
```

`read_only?/0` and `parallel_safe?/0` still work as shorthands, but declared
metadata wins wherever the two disagree, and `Lemieux.Tool.read_only?/1`,
`parallel_safe?/1` and the scheduler all read the same answer from the
descriptor. `Lemieux.Tool.approval/1` returns `:never`, `:always` or
`:policy` from `policy.approval` for a permission layer to act on; the
library itself enforces none of it.

A tool that works with files goes through `Lemieux.Environment` (see the
context's `:environment`) rather than `File`, so a host's sandbox or container
applies to it. One that replaces whole files should also consult
`Lemieux.Tool.FileState`, as `write` does, so it never overwrites what the
session has not seen.

## Descriptor v1

Every tool is represented by `Lemieux.Tool.Descriptor` before execution and in
the durable request snapshot. Existing behaviour modules and configured
structs need no migration: Lemieux infers conservative identity, origin,
effects, policy, deadline, output limit, concurrency and lifecycle metadata.

A host that knows more wraps its executor explicitly:

```elixir
alias Lemieux.Tool.Descriptor

ticket_read =
  Descriptor.new(MyApp.Tools.TicketRead,
    identity: %{
      "namespace" => "acme",
      "contract_version" => "2026-08-16"
    },
    origin: %{
      "type" => "hex",
      "package" => "acme_tickets",
      "version" => "2.1.0"
    },
    interface: %{
      "output_schema" => %{
        "type" => "object",
        "required" => ["ticket"],
        "properties" => %{"ticket" => %{"type" => "object"}}
      }
    },
    effects: %{
      "class" => "read",
      "resource_types" => ["ticket"],
      "resource_scopes" => ["tenant"]
    },
    policy: %{"approval" => "never"},
    runtime: %{
      "timeout_ms" => 5_000,
      "max_output_bytes" => 20_000,
      "concurrency" => %{
        "class" => "resource",
        "resource_key" => "tickets"
      }
    }
  )
```

The model still sees only `name`, `description` and the input schema. The full
descriptor is renderer-neutral audit evidence. Its digest covers the contract;
the implementation digest covers the loaded BEAM module or MCP definition.
The executor itself is never serialized because it may contain functions,
pids or credentials. A configured descriptor must therefore be supplied again
when resuming, just like any configured struct tool.

The descriptor is not a global registry. Catalogs remain explicit and
session-local, so two tenants in one VM cannot race to redefine a name.

## Structured results

Legacy text returns remain valid:

```elixir
{:ok, "ticket ABC-123 is open"}
```

A tool with a typed or rich result returns `Lemieux.Tool.Result`:

```elixir
alias Lemieux.Tool.Result

{:ok,
 Result.new("ticket ABC-123 is open",
   structured_content: %{
     "ticket" => %{"id" => "ABC-123", "state" => "open"}
   },
   content: [%{"type" => "resource_link", "uri" => "ticket://ABC-123"}],
   artifacts: [%{"uri" => "artifact://ticket-ABC-123.json"}],
   cost: %{"usd" => 0.001}
 )}
```

`model_text` is the bounded projection sent back to the model. Structured
content, MCP content blocks, artifacts, cost and metadata are retained in the
`:tool_result` entry for audit and host rendering. If structured evidence
exceeds its output budget, Lemieux replaces it with its byte count and SHA-256
rather than writing invalid partial JSON. Rendering hints are ordinary
untrusted metadata; policy must use descriptor fields, never presentation.

### Images and documents

A result can also show the model an image or a PDF. Build each with
`Lemieux.Tool.Attachment.new/4` and pass them as `attachments:`:

```elixir
alias Lemieux.Tool.{Attachment, Result}

{:ok,
 Result.new("screenshot of the login page (1280×800)",
   attachments: [Attachment.new(:image, "image/png", png_bytes, path: "login.png")]
 )}
```

The shape is the one a prompt's `@path` attachment already has
(`"kind"`, `"media_type"`, base64 `"data"`, `"bytes"`, `"size"`, `"path"`), so
the estimator, the provider seam and compaction treat both alike. Rules:

- **Ask before attaching.** The tool context's `input_modalities` says what the
  session's model can be shown besides text (`[:text, :image, :pdf]`), or
  `:unknown`. Attach only when the kind is in the list, and otherwise say in
  `model_text` what the file is. `Attachment.accepted?/2` answers the
  question; unknown counts as no. An image a model cannot read is a provider
  refusal on every later request, because the transcript keeps it.
- **Say what is attached in the text.** A request that no longer carries the
  attachment, or a provider that cannot, still has the words.
- **Limits.** Images over 3.5 MB and documents over 5 MB are not attached,
  and one result carries at most five. What is left out is named in the text
  (`Attachment.limit/1`, applied to every result at collection).
- **Not audit evidence.** Attachments are outside `Result.to_map/1`, so the
  structured-evidence budget cannot strip them, and they are stored once, in
  the `:tool_result` entry's `"attachments"`.

The session enforces the first rule as well: attachments a model cannot read
are dropped from the result it records, with a sentence saying so, because an
MCP server attaches whatever it produced. Requests resend only the newest
image-carrying results (four by default, shed four at a time so a cached
prefix changes rarely; the session's `:keep_media` option); the transcript
keeps them all. `read` returns PNG, JPEG, GIF and WebP files as images and PDFs
as documents under these rules, and converts a PDF with `pdftotext` through the
environment when it cannot attach it.

## Module tools, configured tools and wrappers

A tool is a module implementing `Lemieux.Tool`, or a struct whose module
implements `Lemieux.Tool.Configured` — the same four operations with the
struct in front. The struct plane exists for tools that carry runtime state a
module cannot: `Lemieux.Tools.Bash.new/1` around a host's command runner,
`Lemieux.Tools.WebSearch.new/1` around a backend and a budget, the `lmx`
skill loader around the files it discovered. Validation accepts any struct
whose module exports the four functions; declaring the behaviour buys
compile-time checking, and a struct that is short of a callback is told which
one and where the contract lives. A configured tool is host state: it is not
recorded in the transcript and must be passed again on resume.

`Lemieux.Tool.Override` changes what the model reads about a tool — its
description, name or schema — without touching what runs, and keeps the
wrapped tool's implementation digest because the code is the same. Given
`before:` or `after:` it also wraps execution: `before` may rewrite or refuse
the arguments, `after` receives the wrapped tool's return verbatim — a
`{:stream, enumerable}` included; wrap the enumerable, do not collect it —
and decides the result. A wrapping override folds the wrapper's digest into
`identity.implementation_digest` (pass `digest:` for a name that survives
recompilation) and lists `"run"` in `origin.overrides.fields`, so evidence
tells a decorated tool from a described one.

Everything that layers onto a catalog goes through `Lemieux.Tool.decorate/2`,
which applies `%{name => (tool -> tool)}` to a tool list in place and raises
on a name that matches nothing or is given twice. Learning overlays and
session profiles compose their descriptions through it; a host that wants an
audited `bash` writes one wrapper and applies it the same way. The defaults
themselves come from `Lemieux.Tools.default/0`, and
`Lemieux.Tools.default(except: ["write"])` is how a host drops one without
rebuilding the list.

## Host profiles

The host owns tenant identity, RBAC and policy. It narrows a session with a
JSON-shaped `tool_profile`:

```elixir
Lemieux.start_session(
  tools: Lemieux.Tools.default() ++ [Lemieux.Tools.Eval],
  tool_profile: %{
    "id" => "shared-standard",
    "shared" => true,
    "allow" => ["read", "write", "edit", "bash"],
    "human_channel" => false,
    "enabled_by" => %{"actor" => "tenant-admin", "policy" => "agents-v3"}
  },
  ...
)
```

Allowlist entries may be model names such as `read` or canonical names such as
`lemieux/read`. A shared profile with `allow: "all"` still leaves tools that
declare `default_off_shared`—currently `elixir`—disabled unless the allowlist
names them explicitly. `web_search` and `web_fetch` are not in that class;
they are configured tools that are simply absent until a host adds them. A
tool requiring a human channel, such as `ask_user`, is unavailable when
`human_channel` is false.

The sanitized profile and `enabled_by` evidence are recorded with each
request. They are not restored as authorization. A host resuming a transcript
must resolve and pass current tenant policy again. Session-level
`disable_tools/2` can narrow the authorized catalog further; it cannot enable
a tool the host profile denied.

`/attach` in `lmx`, which lets the `elixir` tool evaluate inside a running
application, is a person's command, not something the model can ask for. It
is not in the `elixir` schema, and a shared host must gate it separately.

## Execution envelope

All native, configured, delegated and MCP tools use the same supervised path:

- the descriptor deadline is bounded by session `tool_timeout_ms`, one hour
  by default. A descriptor that declares no `runtime.timeout_ms` — most
  tools, `write`, `edit` and MCP tools among them — gets `tool_timeout_ms`
  itself. The deadline a call actually got is in its context as
  `deadline_ms`, so a tool that waits on something it started can hand that
  something a shorter clock — `delegate` gives its group the call's deadline
  less the time the group needs to settle;
- model text and structured evidence are bounded by `tool_output_bytes`
  (120,000 by default) and the descriptor's lower limit — `bash` declares
  30,000 and `read` 60,000, so the session default mostly decides how much a
  `delegate` call may bring back, and `tool_output_bytes` is in every tool's
  context so a tool that renders a document can fit it rather than have its
  JSON cut afterwards;
- exclusive tools are barriers;
- resource-keyed tools overlap different resources but serialize the same key;
- declared parallel readers run only after governed calls in the wave;
- cancellation, timeout, crash, denial, unavailability, invalid arguments,
  ordinary error and success are distinct `outcome` values: `:cancelled`,
  `:timeout`, `:crashed`, `:denied`, `:unavailable`, `:invalid_arguments`,
  `:error` and `:ok` — and a lost result whose effect cannot be inspected is
  `:unknown`, see [Receipts](#receipts-and-unknown-outcomes) below;
- duration, output bytes, descriptor identity/digest and declared external
  cost are written to the result entry.

A background bash start completes inside this envelope after it has handed
ownership to `Lemieux.Background`; the command's own deadline and bounded
capture then belong to that supervised resource. Poll and await observations
still pass through ordinary hooks and transcript results. A wait deadline does
not cancel the resource. See [Background commands](tool-contracts.md#background-commands).

The host deadline is an execution cap; it does not rewrite a tool's declared
input schema. Set `tool_timeout_ms` at or above every timeout maximum advertised
by the catalog, or wrap the tool in a session-local descriptor whose schema and
runtime deadline both state the lower limit. Otherwise the model can validly
request a duration that the host will stop early.

Approval is inside that same execution clock. Keep `tool_timeout_ms` at least
as large as `approval_timeout` for tools that can park (`ask_user`, approvals,
and MCP elicitation), or the outer tool deadline can win before the parked call
returns its clean timeout result.

Hooks remain the policy and live-observation seam. `before_tool_call` receives
the complete serialized descriptor in `context.tool_descriptor` and may allow,
deny, rewrite or park the call. `after_tool_call` retains its compatible
`{:ok, model_text} | {:error, model_text}` observation contract. Accounting
that must survive a task crash should read transcript entries.

## Receipts and unknown outcomes

A crashed `read` is a crashed `read`: the workspace is there to inspect and the
call is safe to repeat. A crashed `send_email` that crashed *after* the
provider accepted the message has succeeded, and a result that calls it a
failure sends a model into sending it twice. `Lemieux.Tool.Receipt` is the
smallest protocol that tells the two apart in an append-only transcript.

**Unknown is an outcome.** A tool whose effects the harness cannot look at
declares so in its descriptor — `"effects" => %{"class" => "external"}`, or
an explicit `"receipt" => true` — and every MCP tool is taken to have declared
it, because a server's tool is remote by definition and its `readOnlyHint`
costs nothing to claim. For such a tool a result lost to a crash, a deadline
or a cancellation is written with `outcome: :unknown` and text that says the
effect may have happened and must be checked before the call is repeated.
`"idempotent" => true` or `"receipt" => false` opts a tool out. A result lost
because the *session* ended is unknown for every tool, since nothing at all is
known about it — and that is what makes a transcript left inside a tool wave
resumable: on resume the session answers every unanswered call as unknown,
because a request that leaves a call unanswered is one every provider
refuses.

**A receipt survives the call.** The moment the remote side has acknowledged
an effect — a message id, a ticket key — a tool calls
`Lemieux.Tool.Receipt.record(context, receipt)` with a JSON-shaped map, and
the session keeps it for as long as the call runs and emits
`{:tool_receipt, %{call_id:, name:, receipt:}}`. If the call completes, the
receipt is written with its result; if the call is lost, the receipt is
written with the unknown outcome and quoted in the text, so the model can
reconcile against it rather than guess. A tool that recorded a receipt has
said its effect is committed, so its lost result is unknown whatever its
descriptor says.

The `:tool_result` entry carries `"receipt"` only when one of the two applies:
`"reported"` is the map the tool recorded and `"lost"` is why the outcome is
unknown — `"crashed"`, `"timeout"`, `"cancelled"` or `"session_ended"`. A
completed call that recorded nothing is the shape it always was. None of this
makes a tool idempotent or retries it; it changes what the model is told, and
a model told the truth about an unknown outcome is the whole mechanism.

## Catalog evidence and exact token counts

Every `:request` entry has both the provider-visible definitions and a
`catalog` snapshot containing:

- exact canonical serialized definition bytes and their SHA-256;
- byte count, model, tokenizer and token count;
- enabled and disabled descriptor snapshots;
- descriptor and implementation digests, origin and provenance;
- the effective host profile.

Lemieux does not guess a tokenizer. A host that has the active provider's
tokenizer supplies an exact counter:

```elixir
tool_token_counter: fn model, serialized_catalog ->
  {:ok, tokenizer_name, MyApp.Tokenizer.count(model, serialized_catalog)}
end
```

Without it, `tokenizer` and `token_count` are `nil`; `bytes` and SHA-256 remain
exact. Provider-reported request usage is still authoritative for billing.

## MCP preservation

MCP tool definitions retain `outputSchema`, annotations, `_meta`, selected
protocol version and server identity. Call results retain structured content,
all JSON content blocks and result metadata in `Lemieux.Tool.Result` while
still producing a deterministic text projection. Unsupported content is not
silently dropped: the model sees a bounded placeholder and the raw block stays
available to the host.

An image block (`{"type": "image", "data", "mimeType"}`) and an embedded
resource whose `blob` is an image or a PDF become result attachments, subject
to the rules under [Images and documents](#images-and-documents). The text
names what was attached in place of the placeholder, and the retained block
keeps its type, media type and size but not its bytes, which are stored once,
in the attachment.

MCP annotations are preserved as server claims, not promoted to trusted
policy. A remote `readOnlyHint` does not make a call parallel-safe or grant it
read-only authority.

## Comparing tool catalogs

Whether a tool earns its place in a catalog is a measurement, and the
benchmark runner (`Lemieux.Benchmark`, experimental) can make it. Run each
catalog as an arm on the `Lemieux.Benchmark.Runtime.Native` runtime with its
own `session_options:` carrying that arm's catalog and profile, and keep the
manifest, provider and model, workspace snapshots, turn and cost limits and
repetitions the same.

The native observation includes `tool_metrics`: catalog bytes/tokens and
tokenizers, calls, errors, denials, unavailable calls, timeouts, output bytes,
declared external cost, descriptor digests and profile ids. Runtime summaries
include mean input/output tokens, catalog bytes/tokens, calls and errors.

The corpus, credentials and richer comparison tools remain the host's.
Declare the arms and decision thresholds before representative runs. See
[Benchmarking](benchmarking.md#evaluating-tool-profiles).

## Commands, files and the environment

`bash` runs every command in a fresh shell with `PAGER=cat`, `GIT_PAGER=cat`,
`GIT_TERMINAL_PROMPT=0` and `GIT_EDITOR=true`, so a command that would wait
for a person fails at once instead of timing out; terminal escape sequences
are stripped from its output (`Lemieux.Tool.Escapes`). A `null` or empty
optional argument counts as absent. The local environment starts each command
in a session of its own — `setsid` on Linux, `perl`'s `POSIX::setsid` on
macOS — so nothing it runs can read the controlling terminal, and a timeout
or cancellation kills its whole process group, with the `kill` program or,
on images that ship none, the shell's own `kill`. A small watchdog per
command kills the group if the VM itself dies first.

The shell is `bash`, else `sh`. On Windows it is Git for Windows' bash
(`Lemieux.Environment.Local.find_bash/0`), found at Git's standard install
locations, then in the installation `git --exec-path` reports, then on
`PATH`. WSL's `bash.exe` is never used: it runs commands inside a Linux
distribution, where the credential scrub, `GIT_TERMINAL_PROMPT=0` and the
process-group teardown would not apply. WSL users should run the Linux build
of `lmx` inside WSL. Without a usable bash, commands fail with that
diagnosis.

A command inherits the VM's environment as the host corrected it
(`Lemieux.Environment.Inherited`), less what the credential policy withholds
([Credentials](#credentials)), plus what the caller passes in `:env`. A VM a
release started is not started from the person's environment: `erlexec` puts
the release's own Erlang first on `PATH` and sets `BINDIR`, `ROOTDIR`, `EMU`
and `PROGNAME`, and a person's `erl`, `elixir` or `mix` run with those fails
at once. So a host that runs in a release calls
`Lemieux.Environment.Inherited.put/1` once at boot with the differences, and
`Lemieux.Environment.Local`, command hooks, MCP stdio servers and the
terminal UI's editor apply them; the installed `lmx` does
([What commands inherit](configuration.md#what-commands-inherit)). A host
started from the person's own shell needs nothing.

`Lemieux.Environment.run/3` accepts `:env` (`[{name, value | false}]`, `false`
unsets) and `:max_output_bytes` (an integer or `:infinity`). Three optional
callbacks extend the behaviour: `stream_file/3`, which lets `read` window a
multi-gigabyte file without holding it, `credentials/1`, the policy the
environment applies to what it spawns, and `delete_file/3`, a confined delete
(`apply_patch` falls back to a confined `rm -f` for an environment without it).
`Lemieux.Environment.Sandbox` wraps any of them in macOS Seatbelt or Linux
bubblewrap (`lmx --sandbox`): commands may write only to the working
directory, temporary directories and tool caches, reach no network beyond
loopback, and cannot read the credential locations it hides. The file tools
refuse a hidden path too, as "permission denied". The evaluation node, MCP
servers, hooks and web tools run beside the sandbox, not inside it. The
[trust model](../SECURITY.md#what-lmx-trusts-by-default) lists what it hides.

### Credentials

`Lemieux.Environment.Local.new(credentials: {:scrub, allow})` withholds every
variable whose name contains `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`
(in any letter case) from the commands it runs, background ones included, and
from the Elixir evaluation node, except the names (or `*` globs) in `allow`.
A variable the caller sets explicitly through `:env` is kept. The bare
`Lemieux.Environment.Local` inherits everything; that is the library default,
and `lmx` turns scrubbing on. The rule reads names, not values: a password
inside `DATABASE_URL`, or a variable that only points at a credential file,
still passes. `Lemieux.Environment.Credentials.overrides/2` gives the same
answer to anything else that spawns processes beside the environment.

### Files

`read`, `write` and `edit` accept an absolute path that names something inside
the working directory, and refuse a path outside it, whether it gets there
through `..`, an absolute path or a symbolic link. Confinement is by path: a
hard link inside the tree to a file elsewhere is the same file, so writing it
writes through. `read` streams the file, reports a binary one (a NUL in
its first 8 KB) instead of decoding it, hides the `\r` of CRLF line endings,
cuts a line longer than 2,000 bytes, and stops at a line boundary with
`continue with offset=N` when the window passes its byte cap.

In a session, `write` replaces an existing file only when the session has seen
it — read, written or edited it — and it has not changed since
(`Lemieux.Tool.FileState`); otherwise it asks the model to read the file first.
`edit` matches through line-ending, byte-order-mark, line-number-prefix,
trailing-whitespace, indentation and whitespace differences, but only ever to
one place (`Lemieux.Tools.Edit.Match`); it shows the edited lines, points at the
closest text when nothing matches, and warns when the file changed since the
session last saw it. `read` returns an image (PNG, JPEG, GIF, WebP) or a PDF as
an attachment when the model accepts that input, extracts a PDF's text with
`pdftotext` when it does not, and otherwise describes the file; see
[Images and documents](#images-and-documents).

### Search and patches

`Lemieux.Extensions.Search` adds two read-only, parallel-safe tools after
`read`; `lmx` applies it by default, and the library's `Tools.default/0` stays
read, write, edit and bash.

- `grep` takes `pattern` (a regex; `literal: true` for a fixed string), and
  optionally `path`, `glob`, `output_mode` (`content`, `files_with_matches` or
  `count`), `case_insensitive`, `context` (0–10 lines) and `max_results`
  (1–1000, default 100).
- `glob` takes `pattern`, and optionally `path` and `max_results` (1–2000,
  default 200).

Both honour `.gitignore`, stay inside the working directory, cut lines at 300
characters and output at 30 KB, and say when they stopped early. They search
with `rg` through the session's environment when it is installed, else list
files with `git ls-files`, else walk the tree skipping dependency and build
directories; glob patterns are matched the same way whichever backend
answers.

`apply_patch` takes one `input`: a patch in the format GPT-5-family models
write (`*** Begin Patch`, `*** Add File:`, `*** Update File:`,
`*** Delete File:`, `*** Move to:`, `@@` context and `+`/`-` lines,
`*** End Patch`), also accepting a heredoc wrapper, a missing envelope and
unified-diff hunk headers. It is all or nothing: every hunk is matched in
memory first, line endings and a byte-order mark are preserved, and a hunk
that does not match reports the closest line. It follows the same
`FileState` rules: deleting a file the session has not seen, or that changed
since, is refused; an update to a stale file proceeds with a note, because a
hunk only changes lines its context matched. `Lemieux.Extensions.ApplyPatch`
swaps it in for `edit` when the configured model is GPT-5 family, which
`lmx` does by default.

### Checkpoints

`Lemieux.Extensions.Checkpoints` records what the agent's tools change, turn
by turn, so a host can offer undo; a turn is everything the agent did between
one prompt and the next. `lmx` applies it with `git: true` and offers
`/undo`, `/rewind N` and `/redo`; [Taking changes back](everyday.md#taking-changes-back)
is the guide for using them. This section is the contract underneath.

**What is recorded.**

- Before `write`, `edit` or `apply_patch` changes a file, its previous
  contents (or that it did not exist), per session and turn, in a directory
  the host chooses (`lmx`: `~/.lmx/checkpoints`). `.env` and other ignored
  files are saved like any other. A file over `:max_file_bytes` (10 MB) is
  changed without its contents being saved, and undo names it as one it
  could not restore. After the tool runs, a digest of what it left is
  recorded, and recorded again by an `after_tool_call` hook once the
  post-tool hooks registered before it (a formatter, say) have run.
- With `git: true`, each `bash` and `elixir` call is bracketed by two git
  trees of the working directory, taken just before and just after the call
  from a copy of the repository's index; the repository's own index,
  branches, stash and refs are never touched. Each call has a window of its
  own. A call that is cancelled or times out is snapshotted when its task
  exits, by a watcher under the runtime's task supervisor.
- A tree holds tracked files, and untracked files up to 1 MB: at most 2,000
  across the whole repository, those in directories git tracks first. What a
  tree leaves out is still listed, by size, modification time and inode, up
  to 2,000 entries: ignored files such as `.env`, larger or later untracked
  files, and wholly ignored directories such as `_build/` (by name only). So
  undo can name what a command changed even where it cannot put it back.
  `HEAD` and a digest of the refs are recorded too.
- A tracked file that a filter attribute names a driver for (Git LFS,
  git-crypt, `nbstripout`) is left as the index has it and listed, not
  saved, because what git holds for it is the filter's output, a pointer or
  ciphertext. Undo names such a file when a command changed it, rather than
  putting it back. What a file tool changes in it is saved and undone like
  any other change, and a file marked `-filter` is snapshotted like any
  other file. A submodule is kept as the commit the superproject records
  for it.
- What could not be recorded is noted with the turn
  (`Lemieux.Checkpoint.mark_unrecorded/4`), so undo reports it rather than
  answering as if the turn did nothing: a command run outside a git
  repository, in a directory the repository ignores or in a repository
  whose `core.worktree` names another directory, a snapshot that failed, a
  command started in the background, an MCP tool call.
- When `Lemieux.Extensions.Verify` is given the checkpoint directory (its
  `:checkpoints` option), as `lmx` does, the post-edit check runs in a
  window of its own, recorded with the turn whose edits it checked: undo
  takes back what the check changed, as far as it would for a command.
  Outside a git repository the check is noted as unrecorded instead. A
  host brackets its own file-changing work the same way, with
  `Lemieux.Checkpoint.around/4`.

Not seen at all: what a command changes inside a wholly ignored directory,
beyond the directory appearing or going; an empty directory a command
creates; what a command changes inside a git submodule; anything outside the
git repository the command ran in, such as a file in the home directory;
what a background command changes after its call returns; what hooks
change, except when a post-tool hook registered before the extension, such
as a formatter, rewrites the file a file tool just changed (above); and
tools added to the catalog after the extension applied, including a host's
own. Without `git: true` the extension records only the file tools, and
nothing is noted; a post-edit check that `Lemieux.Extensions.Verify`
brackets with `:checkpoints` is still snapshotted.

**Nothing the repository configures runs.** Snapshots and undo's restores
run git on this machine, outside any sandbox the commands run in, in a
repository those commands can write. A repository's configuration names
programs git starts by itself (hooks, `core.fsmonitor`, the clean, smudge
and process commands of a filter driver), so every git that reads content
or objects runs in a git directory of its own: made fresh for each
snapshot or undo (mode `0700`, a random name) under the session's `git/` in
the checkpoint directory, removed afterwards, and handed the work tree, the
repository's object store and, for a snapshot, a copy of its index. The
repository's `.git/config`, hooks and `info/` are read only as data. No
hook, no `core.fsmonitor`, no filter and no submodule's own configuration
runs, and only the settings that decide how a file's bytes and name read
(line endings, letter case, the executable bit, symbolic links, ignore and
attribute files) are copied in. What git prints as a warning is not taken
for part of its answer. A repository whose `core.worktree` points at another
directory is not snapshotted. Keep the checkpoint directory out of the
commands' reach, since a command that could write it could configure the
git that runs there: `lmx`'s is in `~/.lmx` by default, which `--sandbox`
hides. A host that reports a repository's state the same way uses
`Lemieux.Checkpoint.Git.status/2`, `locate/1` and `revision/1`. `lmx` uses
them for the git state in the prompt's environment block, the startup
`/undo` notice and `/doctor`'s checkpoints row, the revision a scout's
snapshot names, and the A2A server's revision and dirty check. `status/2`
also reads from a private git directory, made under its `:scratch` option
when given one. Without it, as `lmx`'s environment block and A2A dirty
check call it, the directory is made in the system's temporary directory,
which a sandbox lets commands write: nothing the repository configures runs
there either, but a command left running in the background could race to
add a setting of its own. A host that wants that closed passes a `:scratch`
directory commands cannot write.

**Undoing.** `Lemieux.Checkpoint.undo/3` reverts the most recent turn not
already undone, file by file, and returns a report:

| Key | Meaning |
| --- | --- |
| `restored`, `deleted` | What it put back, and what it removed because the turn created it |
| `conflicts` | Files changed since the agent changed them, left alone |
| `unrestorable` | Files it could not put back: too large to have been saved, in a snapshot `git gc` has since removed, changed by a command that no snapshot saved (an ignored file, a file stored through a filter driver), or outside the working directory |
| `uncertain` | Files it put back but cannot vouch for: one the agent edited inside a wholly ignored directory after a command ran there |
| `not_undone` | What the turn did that undo does not reverse: commands and MCP tool calls it could not record, moved refs |
| `next`, `action`, `commands?` | The turn a second `undo/3` would take (`nil` when none is left), whether this was an undo or a redo, and whether anything but the file tools ran in the turn |

It never stops at the first conflict. A turn with nothing to put back, such
as one that only ran unrecorded commands, is still the turn it reports on;
it never silently undoes the turn before.

- `force: true` restores over conflicts. Right after an undo that left files
  alone, with no newer recorded turn, it finishes that undo instead.
- `rewind/4` undoes the last N turns, newest first.
- `redo/3` puts back what the last undo replaced, with the same conflict
  check. A forced redo keeps what it overwrote in the store.
- The errors are `:nothing_to_undo`, `:nothing_to_redo`,
  `{:unwritable, path}` (nothing was ever recorded because the store cannot
  be written) and `:still_recording` (a command stopped a moment ago is still
  being snapshotted; `:await_ms` sets how long undo waits, five seconds by
  default).

A path that a command and a file tool both changed in one turn goes back to
its state before the first of them: a generated file the agent then edited
is deleted, not "restored" to the generator's output, and an ignored file a
command rewrote before the agent edited it is named as unrestorable. A change
the person saves while one of the agent's commands or the post-edit check
runs cannot be told from theirs and is undone with it; `redo/3` takes that
back. A change saved between commands is the person's: each file goes back
to just before the agent's first change to it in the turn.

Undo changes files and nothing else. It never moves `HEAD` or a
ref, never touches the index, branches or stash, and does not undo the
agent's git commands: after an agent's `git checkout -b x && git commit`, it
leaves you on `x` with the reverted files as uncommitted changes. Report
paths are file names as the file system has them, and need not be valid
UTF-8. Files are read and written through the session's environment; git
snapshots and restores run on this machine, in their private git directory.

**Retention.** The store keeps every saved file, `.env` contents included,
what each undo replaced and what a forced redo overwrote, until
`Lemieux.Checkpoint.forget/2` deletes the session or somebody deletes the
directory. Nothing prunes it. `lmx`'s store is created readable only by you.
Snapshots also leave unreferenced objects in the repository's own
`.git/objects` until `git gc` prunes them; an undo after that reports the
snapshot as gone.

In `lmx`, checkpoints are off under `--config none` without `LMX_HOME`, or
with `"disabled_extensions": ["checkpoints"]`, and `/undo` says so. `lmx run`
records them too: resume the session in the terminal UI (`lmx --resume ID`)
and `/undo` there.

## Background commands

Long-running monitors, development servers, and shell scripts should not hold
an agent tool call open. The default `bash` tool can start them under the
mounted Lemieux runtime, then poll or await the same task later.

### Model-facing bash lifecycle

Start a command without waiting for it:

```json
{"command":"mix test --listen-on-stdin","background":true}
```

The result contains a `task_id`. Poll without blocking:

```json
{"task_id":"01K..."}
```

Or await completion for a bounded interval:

```json
{"task_id":"01K...","wait_ms":30000}
```

Or stop it:

```json
{"task_id":"01K...","cancel":true}
```

An expired `wait_ms` leaves the command running and returns its current
snapshot. The model can work on something else, poll again, await again, or
cancel it — a dev server started to check one page otherwise holds its port
until the session ends.
`background_timeout_ms` controls the command's lifetime independently of any
individual wait; it defaults to one hour and is capped at 24 hours. Ordinary
synchronous bash retains its existing `timeout_ms` behavior.

Every observation includes a typed structured result as well as model text:
task and session ids, command, status, exit status, captured output and byte
count, error, timestamps, and duration. A non-zero shell exit is `:exited` with
that status, not a tool failure.

### Host API

Embedded hosts use the same service directly:

```elixir
{:ok, task_id} =
  Lemieux.Background.start(
    supervisor: MyApp.Agents,
    session_id: Lemieux.Session.id(session),
    owner: session,
    command: "mix test --listen-on-stdin",
    cwd: worktree,
    timeout_ms: :timer.hours(2)
  )

{:ok, snapshot} =
  Lemieux.Background.poll(MyApp.Agents, session_id, task_id)

case Lemieux.Background.await(MyApp.Agents, session_id, task_id, 30_000) do
  {:ok, finished} -> finished
  {:error, {:timeout, current}} -> current
end
```

`cancel/3` stops a running command. Task lookup requires both its id and owning
session id, so an id from another session is indistinguishable from a missing
task.

### Lifecycle and bounds

Background commands are runtime resources, not durable transcript resources.
Tool calls record the id and every observed snapshot, but replay cannot revive
an operating-system process after its runtime has exited. A task monitors its
owning session and is killed when that session terminates. Completed tasks stay
queryable for one hour, then expire.

Captured output is memory-bounded to one megabyte by default. When more arrives,
Lemieux retains the head and tail and inserts the exact omitted byte count. The
command keeps running; reaching the observation cap is not secretly treated as
completion. The local environment's eight-megabyte foreground cap does not
apply here — a background task passes `max_output_bytes: :infinity`, because it
already bounds its own memory — so a long-lived, chatty command runs until it
exits or its lifetime ends rather than failing for the size of its log.
Demand-driven ExCmd backpressure still applies.

Background execution uses the session's `Lemieux.Environment`, so container or
remote environments keep the same ownership, timeout, and event contract. A
configured `Lemieux.Tools.Bash.new/1` runner works in the background too; it
receives the command, cwd, and full background lifetime.

### Completion subscriptions

Hosts can await a mailbox event while continuing independent work:

```elixir
:ok = Lemieux.Background.subscribe(MyApp.Agents, session_id, task_id, self())

receive do
  {:lemieux_background, %{event_id: event_id, task: terminal_snapshot}} ->
    # Persist/deduplicate this receipt before deciding whether to wake an agent.
    {event_id, terminal_snapshot}
end
```

Registering after completion delivers the retained terminal snapshot immediately.
Repeated registration by the same process while running is idempotent. A later
registration replays the same event id. `unsubscribe/4` removes interest; it
cannot retract a message already sent. Dead observers do not affect execution.
These are runtime mailbox events, not durable delivery acknowledgements. Hosts
own notification persistence and whether another model turn is authorized.
