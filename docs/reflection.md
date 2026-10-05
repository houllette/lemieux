# Reflection and feedback

**Experimental.** May change in any 0.x release.

`/reflect` reviews how Lemieux could have served the current task better. Use it
in the TUI after a useful, confusing or interrupted session.
It produces a written assessment with evidence references, a few prioritized
improvements, and tests or experiments that could validate them.
`/reflect opportunities` asks the same review for records instead of prose and
writes each one to the feedback ledger.

This is feedback for harness development. It does not modify files, install a
skill, change a profile or claim independently confirmed improvement.

## What it reviews

The workflow gathers evidence from the full stored transcript before applying
compaction or clear filtering:

- Goals, public answers, user decisions and corrections.
- Tool calls, invocation errors, command exits, timeouts and recovery.
- Cancellation, compaction, fork and context boundary events.
- Model requests, effective configuration and available per-response usage.
- Request-linked aggregate token/cache/cost observations and missing reports.

A user interruption is context, not proof of failure. For example, stopping work
to move diagnosis into another session does not mean the work had failed.
Successful tool invocation with a nonzero shell exit is also distinct from a
malformed invocation. Unknown token counts, prices and gateway observations stay
unknown. Local requests do not represent provider subscription quota units.

Every entry contributes to aggregate counts and resource accounting. Model context
is bounded: at most 96 KB of event details by default, lowered conservatively for
small known model windows, with each payload excerpt limited to 2,400 characters.
Recent errors and human/boundary events take precedence over routine successes.
Head and tail excerpts preserve both initial arguments and terminal results.
The report names omitted events and clipped payloads. An omitted detail cannot
support a finding; use `lmx log SESSION` for the original evidence when needed.
Private reasoning blocks are excluded; common credential fields and token strings
are redacted. This is not a general-purpose secret scanner for arbitrary prose.

## Choosing the right improvement

For an explicitly designated extension, reflection prioritizes its instructions,
tools, deterministic workflow and development cases, while separating changes
that belong in base Lemieux. Portable profiles provide a digest and designation
through normal harness snapshots. Resumed sessions can recover that designation.
Historical first-party builder prompts are recognized as a labeled inference.

In base Lemieux, the assessment considers a clearer one-off prompt, a reusable
skill for portable instructions, or a native extension when specialized tools,
orchestration and measurable tuning are warranted. It may recommend no new
abstraction. An extension and an ecosystem plugin remain different concepts.

## Execution and persistence

`/reflect` requires an idle session and never interrupts one implicitly. It uses
the selected provider/model/effort, normal request and cost admission, lifecycle
hooks, streaming and cancellation. It requests one assessment without tools;
unexpected model tool calls are denied without executing them. A stop-hook veto
ends the assessment instead of starting an autonomous repair loop.

The canonical request has `kind="reflection"` and contains the evidence projection
in its system text. The ordinary transcript records the `/reflect` prompt and
answer. Later coding requests retain the original instructions, tools and output
schema rather than inheriting the reflection mode or its large evidence bundle.
Repeated reflection includes earlier reflection usage in cumulative accounting.

Reflection is not a mode of the session. `Lemieux.Reflection.reflect/2` reads
the transcript from `Lemieux.Session.snapshot/1`, builds the evidence, and hands
the session a `Lemieux.Session.Aside` — the loop's one generic facility for a
tool-free request on a host's behalf, with its own system text and a kind to
record it under. Everything above (admission, hooks, the denial of tool calls,
the stop-hook rule) is what the session does for any aside; nothing in
`Lemieux.Session` names reflection. A host that wants a different review
prompt, or a judge scoring the run from outside, writes another caller.

No gateway is required. A model connection is needed to generate the assessment;
the deterministic evidence report can be gathered without one.

## Library hosts and gateway evidence

```elixir
# Pure evidence gathering: no provider call or filesystem mutation.
report = Lemieux.Reflection.gather(Lemieux.Session.snapshot(session).entries)

# The same streamed workflow as the built-in slash command.
:ok = Lemieux.Reflection.reflect(session)
```

Hosts designate native extensions through the existing session option:

```elixir
harness_context: %{
  "extensions" => %{"agent" => %{"name" => "MyExtension", "revision" => "revision-id"}}
}
```

`Reflection.reflect/2` and `Reflection.gather/2` also accept JSON-shaped
`:host_evidence`: a host gateway's own observations of the same requests.
`Lemieux.Reflection.HostEvidence` projects it against the session's transcript
and the reflection request carries that projection, not the raw map.

```elixir
Lemieux.Reflection.reflect(session,
  host_evidence: %{
    "source" => "ixway",
    "instance" => "https://gateway.example",
    "scope" => %{"tenant_id" => "t1"},
    "collected_at" => "2026-09-17T10:04:00Z",
    "window" => %{"from" => "2026-09-17T10:00:00Z", "to" => "2026-09-17T10:04:00Z"},
    "records" => [
      %{
        "request_id" => "req_1",
        "observed_at" => "2026-09-17T10:01:12Z",
        "input_tokens" => 100,
        "output_tokens" => 20,
        "cost_usd" => 0.001,
        "status" => "ok"
      }
    ],
    "totals" => %{"input_tokens" => 100, "output_tokens" => 20}
  }
)
```

The projection answers four questions before it reports any number:

- **Provenance** — source, instance, scope and collection time, and whether
  the evidence was attributed at all.
- **Freshness** — how far the gateway's window or collection time sits behind
  the session's last entry, and whether it covers the session. A gateway that
  stopped collecting first has an excuse for every record it is missing.
- **Missingness** — local requests with no gateway record, gateway records
  matching no local request, records that arrived twice, and records carrying
  no request id. Each is listed explicitly and bounded to 25 entries with the
  true count kept.
- **Correlation** — which gateway record belongs to which `request` entry, by
  the request id the transcript already records, with the entry id and
  sequence number so a finding can cite it.

Reconciliation puts local and gateway totals side by side with a per-counter
`agrees` / `differs` / `unknown` verdict and the signed difference. **They are
never summed**: two observations of one request are still one request. A
gateway aggregate supplied as `totals` is used as given rather than recomputed
from its records, because an aggregate the gateway computed is what the
gateway will bill. A counter the gateway did not report stays unknown, never
zero.

Absent evidence is stated (`availability: "not supplied"`) rather than left as
an empty section, and local accounting remains complete on its own terms.
Evidence that is not a JSON object is reported as `"unusable"`, which is a
different fact from having no gateway.

There is no Ixway client in the core and no automatic fetch: this is a data
seam a host fills. `Lemieux.Ixway` is inference routing and supplies none of
it.

## Mining opportunities as feedback

Reflection has a second mode that asks for records instead of prose:

```elixir
:ok = Lemieux.Reflection.reflect(session, mode: :opportunities)
```

It requests a JSON array of opportunities over the same evidence projection,
under the same request, cost, hook and cancellation rules, and still without
tools. Each element has a `title`; a one-sentence falsifiable `claim` about
harness behavior; a `type`, which is one of `bug`, `missed_requirement`,
`product_requirement`, `style_preference`, `taste` or `unknown`; a
`verifiability` class, which is one of `mechanical`, `environmental`,
`human_review`, `subjective_judge` or `unknown`; the `evidence_entry_ids`
that support it; a `proposed_case` that is null or a prompt, an argv
verifier and allowed changed paths; and a `confidence` between 0 and 1. An
answer that is prose rather than JSON is not an error. It is zero
opportunities, with the prose kept for the operator.

The reading is lenient where leniency loses nothing. An element that wrote a
claim and skipped the `title` keeps its finding and takes a label from the
claim's first sentence: the label is how a person recognises a record in a
ledger, not part of the finding, and dropping the whole element over it would
lose a real opportunity. An element with no claim at all is still
nothing. A reflection cut off by its output limit leaves a half-written array
that parses to nothing, so the interactive command says it was truncated
rather than letting zero read as "the evidence supported none". The session mode
records the answer in the transcript like any reflection; turning it into
feedback records is a separate step.

`Lemieux.Reflection.Opportunities` is the library seam. `mine/2` runs one
bounded, tool-less session over stored entries with the given provider and
model and returns the parsed list with the raw observation. `parse/1` reads
an answer leniently. `record/4` stores each opportunity as a
`Lemieux.Feedback` record with a model actor and `reflection` provenance,
anchored on its first evidence entry. From the command line:

```sh
lmx feedback --mine SESSION [--model provider:model]
```

From inside a session, `/reflect opportunities` in the TUI runs
the same request against the transcript you are already in, then reads its
answer back and records what it named. There is no second reflection to pay
for: the assessment has already streamed and been persisted, so only the
recording remains. `Lemieux.CLI.Feedback.harvest/2` is that second half, and it
ends at the same `record/4`, so a record mined from inside a session is
indistinguishable from one `--mine` produced.

A mined record enters the same triage and case-draft path as a person's
feedback. It can propose a mechanical case, a person must classify it before
`lmx feedback draft-case` accepts it, and it never becomes an asset on its
own. See [Feedback, cases and durable assets](reflection.md#feedback-cases-and-durable-assets).

## Feedback, cases and durable assets

Lemieux provides the local primitives for turning a correction into evidence
and a reviewable change. It does not automatically decide that a proposed
change is better or deploy it. The [roadmap](roadmap.md) tracks open
validation and host integration.

### Capture feedback without changing the conversation

```sh
lmx feedback wayne-gretzky \
  --text "It should have run the formatter before finishing" \
  --scope project --standing-rule
```

Use `--entry ENTRY_ID` for an explicit anchor. Otherwise capture selects the
last stored entry after resolving the session. `--sessions-dir` and
`--feedback-dir` select the stores. The dedicated feedback JSONL ledger keeps
raw prose and interpretation revisions outside the transcript used for
resume/replay.

`/feedback` does the same thing without leaving the session: it offers the
moments a person can point at, takes the prose, asks at most three questions
that change where the record goes, and writes to the same ledger through the
same `Lemieux.CLI.Feedback.capture/2`. The answers are recorded as one
interpretation revision beside the untouched prose, so the ledger says the
routing was asked for rather than inferred. See [the CLI
guide](cli.md#capture-feedback-without-leaving-the-session).

`Lemieux.Feedback` preserves provenance, requested scope and durability.
A classification revision does not overwrite the user's words. Mechanical or
environmental claims can become cases; style/taste and one-off corrections
need an appropriate human decision rather than a fabricated quantitative gate.

Use [session reflection](reflection.md) to ask the model to diagnose a session.
Reflection is a separate budgeted conversation operation, not feedback capture,
case approval or durable asset activation.

A model can name opportunities too:

```sh
lmx feedback --mine SESSION [--model provider:model]
```

`--mine` runs one bounded, tool-less reflection over the stored transcript
and records each opportunity the model names as a feedback record with a
model actor and `reflection` provenance. Mined records enter the same triage
and case-draft path as a person's feedback and never become assets on their
own; see
[Mining opportunities as feedback](reflection.md#mining-opportunities-as-feedback).

### Prepare and review a case

`Lemieux.Feedback.CaseDraft.create/4` freezes an eligible fixture and verifier
outside the approved corpus. `Lemieux.Feedback.Flow.prepare/3` combines that
case draft with an immutable, unapproved asset proposal without a model call.
The host supplies source/output locations, asset content and provenance.

From the command line the same path is two reviewed steps:

```sh
lmx feedback draft-case FB_ID --source DIR --output eval/drafts \
  --prompt "Fix value.txt and rerun the check." --verifier "sh check.sh" \
  --class mechanical
lmx corpus promote eval/drafts/case_ID eval/corpus/local/manifest.json \
  --cluster value-repair --tag repair --allow value.txt
```

`draft-case` freezes the fixture at `--source` and the verifier beside the
record under `--output`. The copy leaves out secret-shaped files by name
(`.env` and `.env.*` except `.env.example`, private keys, credential stores
and the like; `Lemieux.Benchmark.SecretFiles` lists them all) and records each
one in the draft's `"skipped"` list, with the review checklist asking you to
look. The rule reads names only: a key pasted into an ordinary file still
needs that review. `--class mechanical` or `--class environmental`
records the reviewer's verifiability judgment as a revision first, which is
what makes a mined or unclassified record eligible. `lmx corpus promote`
takes the draft directory and a manifest, requires `--cluster`, accepts
repeated `--tag` and `--allow` entries, and takes `--repos-dir` to change
where fixtures land. It runs the grader on a scratch copy of the untouched
fixture and refuses a case whose grader already passes, because such a
case cannot tell a candidate from the seed; `--expect pass` is for
read-only and refusal cases whose grader must pass untouched. Before it runs
anything, it refuses a draft whose fixture contains secret-shaped files and
names them; `--allow-secret-files` (`allow_secret_files: true` in the
library) accepts a deliberate fake-key fixture. It then copies the fixture to
`<manifest dir>/repos/<id>` and appends the task with its cluster, tags and
allowlist. `Lemieux.Benchmark.Corpus.Promote.promote/3` is the library
function behind it.

The [capture extension](https://github.com/houllette/lemieux/blob/main/examples/extensions/capture/README.md) writes the
first draft itself: a `session_end` hook turns a verification command left
failing, or a correction from the person, into a feedback record and a
bounded draft for this review. It writes drafts under `.lmx/drafts/` with a
`.gitignore` of `*`, so `git add -A` never stages one, and its workspace
snapshot skips the same secret-shaped files, plus `lmx`'s own
`.lmx/config.json`.

A case must reproduce the claimed behavior mechanically or through an
appropriate environment verifier. A plausible story or LLM agreement does
not make it an independent fitness function. The person/process constructing
a variant must not be allowed to redefine its decisive grader after seeing
results.

### Version and resolve assets

`Lemieux.Asset.Version` identifies immutable content, scope, parent and
provenance. `Lemieux.Asset.Proposal` records approval;
`Lemieux.Feedback.Flow.approve/3` accepts an actor and updates a pure
`Lemieux.Asset.Registry` projection. The host authenticates that actor and
persists the transaction. These data APIs are not a tenant authorization
service or a file-editing daemon.

`Lemieux.Asset.Resolver.resolve/2` orders release, host, tenant, project and
session layers, enforces aggregate content budgets and reports conflicts
without weakening established safety values. Rollback moves the active
pointer to the recorded prior version; it does not rewrite historical content.
Project-owned changes use ordinary Git review; hosted activation requires
host-owned storage, policy, monitoring and rollback.

### Measure a frozen candidate

`Lemieux.Experiment.Plan` fixes a hypothesis, one-factor control/variant,
metric, sample, stopping rule and allowance. `Lemieux.Experiment.State`
checks host-supplied transition facts. `Lemieux.Experiment.Decision` separates
safety and critical-regression gates from held-out quality and secondary cost
or latency. `Lemieux.Experiment.CodeGate` keeps code release human-owned.

Use the [benchmark guide](benchmarking.md) for paired runs and the
[extension confirmation guide](agent-extensions.md#confirmation-and-qualified-export) for frozen native
extensions. Exposed development cases cannot become hidden confirmation
because a new directory was created. `Lemieux.Benchmark.Corpus` tracks direct
and derived exposure; hosts own truthful case identity and secret custody.

Promoted cases are what the discovery lane consumes.
`mix lemieux.discovery.confirm` holds out the manifest cases a search never
saw and decides with the same `Experiment.Plan` and `Experiment.Decision`,
and `mix lemieux.discovery.cycle` runs a bounded campaign and that
confirmation on every configured model as one generation; see
[Using self-improvement regularly](harness-learning.md#using-self-improvement-regularly).

The sandbox runtime contract validates caller-supplied attestations; it does
not provision a microVM. A local process/worktree and captured dependency
BEAMs are useful for trusted tests but do not prove hostile-code containment.
Unknown usage/cost remains unknown, and reservations are not measured spend.

### Host integration

The [cross-system architecture](host-integration.md) assigns evidence to
Lemieux, advisory analysis to Ixway and governance to an orchestrating host,
a host application that embeds Lemieux and owns durable storage, isolation,
independent evaluation and activation. Its
[adoption requirements](host-integration.md#orchestrating-host-adoption) and
the [acceptance runbook](acceptance.md) define that work.
