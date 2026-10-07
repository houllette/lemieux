# Transcript compatibility

The transcript is Lemieux's durable contract. Resume, fork, inspection and
request reconstruction all read entries written earlier, possibly by a
different application version or on another machine.

## Compatibility rules

- Every entry carries an explicit schema version.
- Readers reject versions and entry types they do not understand instead of
  silently dropping history.
- **Rejecting is a returned error, never an exception.** The behaviour requires
  a non-raising error tuple from `Lemieux.Store.read/2`; the JSONL store
  answers `{:error, {:unreadable, session_id, reason}}` and leaves the file
  untouched. This is the difference between a person being told which build
  wrote their session and a person being shown a stacktrace, and it is the
  seam a version-N-1 reader is added at: teach `Lemieux.Entry.from_json!/1`
  the older shape and the error stops being produced.
- Payloads, usage and host metadata are JSON-shaped with string keys.
- Entries are append-only. Compaction records a summary and cut point; it never
  deletes the conversation it summarizes.
- A fork retains copied entry ids so shared ancestry stays visible.
- Host data belongs in `meta`; library-defined payloads may gain fields as
  their entry contract evolves.

Within a supported schema version, readers must tolerate additional payload
fields. Removing a field, changing its meaning, or adding a new entry type that
older builds cannot safely ignore requires a schema-version change and a reader
for every version the release claims to support.

Lemieux writes ordinary entries at schema version 2 and the state that
extensions save (`extension_state` entries) at version 4. Readers support versions 1, 2,
3, 4 and 5. Version 4 adds the opaque `extension_state` type: older readers
reject it rather than silently losing extension state on resume. A transcript
may contain both versions. Version 2 adds the `harness_snapshot` and
`run_evidence` entry types used by the harness-learning evidence contract.
They are versioned as a schema change, not smuggled into version 1: a
version-1 reader cannot safely ignore either entry without losing the
effective behavior or terminal audit record. Reading a version-1 transcript
preserves the entry's original `v: 1`; any newly appended entries use version
2.

Version 5 is a version-2 entry whose large repeated fields are written as
references. A request snapshot's system prompt, tool schemas and catalog, a
`session` entry's system prompt, and a harness snapshot's tool descriptors and
extension provenance are written in full the first time a transcript holds
them; an identical value later in the same file is written as
`{"$sha256": digest}`. `Lemieux.Store.JSONL` and a resumed session put every
value back, so readers see the payloads that were built, and the file stays
self-contained: the value a reference names is always an earlier line of the
same transcript, so copying one file copies everything it needs. Expanded
entries read back at version 2. A host reading its own store's entries calls
`Lemieux.Transcript.expand/1` first, or starts sessions with
`transcript_dedup: false`. An older build refuses a version-5 line rather than
reading a reference as the value it stands for.

Two related choices shape what the audit record costs. A run writes one
harness snapshot while its behavior digest and correlations are unchanged,
however many requests it makes, and request snapshots do not store the
serialized tool schemas a third time beside the list and the descriptors (the
catalog keeps their size and digest). Measured on a synthetic twenty-prompt
session with a 32 KB system prompt and six tools, the two choices take the
transcript from 1.63 MB to 0.30 MB: request snapshots from 1.11 MB to 0.16 MB
and harness snapshots from 432 KB to 50 KB. The `:evidence` session option
trades the record's fidelity for size further: `:digests` keeps request
snapshots' digests, sizes, entry ids and parameters without the prompt text
and schemas, and `:off` also writes no harness snapshots or run evidence.

Readers also accept version 3 entries, which only experimental builds wrote;
no release writes them. Their `guidance` records are kept as inert evidence:
their usage counts toward historical spend but not the current conversation
window, and guidance is never sent to the provider or restored as policy.

## Replay means two different things

Transcript replay reproduces the durable facts and reconstructs the canonical,
provider-neutral request recorded for a turn. It does not promise that another
model call produces the same tokens, that a tool has the same external effect,
or that provider-library upgrades produce byte-identical HTTP.

UI replay is also not a recording of every streaming delta. Deltas are
transient; the assembled assistant entry is durable. A host reconnects by
reading entries and then subscribing for new events.

Request entries retain the provider-visible tool definitions plus a catalog
snapshot recording the serialized schemas' size and SHA-256 (not the bytes
themselves), descriptor/provenance evidence, enabled state and the effective
host-profile record. Profile evidence is an audit fact, never restored
authority: the current host must authorize a resume again. Tool-result entries
may additionally contain structured content, raw content blocks, artifacts,
cost, descriptor identity/digest, output bytes and a structured outcome.
Providers continue reading the stable `output` text; older readers may ignore
these additive fields under the rule above.

A tool-result entry may also carry `"attachments"`: images and documents the
tool returned, in the same shape a user entry's `@` attachments have (`kind`,
`media_type`, base64 `data`, `bytes`, `size`, `path`). This is an additive field
within schema version 2. A reader that predates it sends the result's `output`
text alone, which always says what was attached. Each attachment is stored
once, in its tool result; requests are built from the transcript and shed
older ones, so a request snapshot records the entry ids it carried, never a
second copy of the bytes.

Three additive fields mark records that are not part of the conversation. An
`assistant` entry with `"partial" => true` is what a model had said when its
stream failed — kept for a reader, never sent again, whether the request was
retried or the turn ended. A `run_evidence` entry with `"degraded" => true`
stands in for a manifest that could not be built, with the run id and the
reason. An `error` entry recording a failed summary carries
`"retrying" => true` when the summary was tried again. A `user` entry with
`"stop_hook" => true` is part of the conversation — the model is sent it — but
was written by a `stop` hook rather than typed by the person; earlier builds
wrote the same feedback without the mark. Requests may also carry
short synthetic user messages the session composes — leading a tail that
begins mid-turn, or closing a summary request. They are never entries: their
ids name the entry they were built beside (`…-continued`, `…-summarise`), they
carry `meta: %{"synthetic" => true}`, and a request snapshot's `entry_ids` may
list them.

CLI sessions may also carry an additive `harness_assembly` field in session
configuration. Its versioned data records composition inputs and the names
of tool-transforming extensions, not callbacks or private options. Only the
CLI uses it to reconstruct the harness from extensions the current host
selected; the core treats it as inert host data. Unknown assembly versions
require an explicit replacement catalog. A live catalog replacement clears
the record. This does not change the entry schema or authorize loading code
from a transcript.

### Delegated tree replay

A delegated run writes `subagent_spawn`, `subagent_steer`, `subagent_result`,
and `subagent_group_result` entries in the parent transcript. Each child is an
ordinary session with its own transcript id. Spawn payloads persist root,
parent, group, and child lineage plus definition, brief, and snapshot digests;
results persist runtime-owned status, usage, and transcript references.

`Lemieux.Subagent.Replay.tree/2` reconstructs the tree after process loss. A
spawn without a terminal child transcript is `:incomplete`; a terminal child
without the matching parent result is `:unreconciled`. Replaying never reruns a
model or tool, and content-addressed artifacts must be revalidated before use.
Live nested subagent events are presentation hints, not durable history.

## Store implementations

`Lemieux.Store` implementations must return entries in append order and make a
completed append durable. A database host should enforce one writer per session
and preserve `seq`; the optional `lock/2` and `unlock/3` callbacks are where a
store does that, and a session refuses to start on a transcript another live
writer holds. The JSONL store keeps its claim in `<id>.lock` beside the
transcript and takes over one whose holder has provably exited.

The JSONL store ignores an invalid final line, because a short append can leave
exactly one torn tail, but reports malformed data in the committed prefix
rather than returning a conversation with a silent hole. Before its next
append it seals that tail — completing a whole entry that lost only its
newline, cutting a fragment back to the last complete line — so the append
cannot turn a torn tail into corruption in the middle of the file. Its append
is process-crash durable and deliberately makes no `fsync` claim.

Before changing the schema, add fixtures from the oldest supported release and
prove that the new reader reconstructs the same public entries and requests.
Keep those fixtures after the migration; compatibility that is tested only
during the release which introduced it is compatibility that will regress.

`test/lemieux/resume_test.exs`, under "a transcript written by a different
build", holds the version-1 fixture and the two refusals. It is hand-written
JSON rather than a transcript produced by a session on purpose: a fixture
generated by the current code proves only that the code agrees with itself.
