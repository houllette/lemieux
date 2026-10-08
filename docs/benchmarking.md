# Benchmarking harnesses

**Experimental.** May change in any 0.x release.

Lemieux includes a small comparative benchmark runner because agent quality is
an empirical question. A native loop can be cheaper, more observable and more
controllable than a wrapped CLI and still be the wrong runtime if it completes
materially fewer real tasks. The runner sends the same tasks through each
runtime you give it, such as a Lemieux session or another agent's command
line, and grades every attempt with a command.

The benchmark code is host-agnostic. It contains no host's private corpus,
vendor CLI flags, credentials or preferred model. A host supplies those and
keeps the resulting artifacts under its own retention policy.

The release-grade corpus, Tribunal Test Mode assertions, policy gates and
standalone Mix task are documented in [Evaluation gates](evaluations.md).

## Manifest

A version-one manifest is JSON. Every task has a stable id, a prompt, a source
working directory and a mechanical grader expressed as an argv vector:

```json
{
  "version": 1,
  "metadata": {"suite": "host-regressions", "revision": "2026-08-15"},
  "tasks": [
    {
      "id": "resume-keeps-tools",
      "prompt": "Fix the failing resume test and run the focused test file.",
      "cwd": "fixtures/resume-keeps-tools",
      "timeout_ms": 600000,
      "grader": {
        "command": ["mix", "test", "test/lemieux/resume_test.exs"],
        "timeout_ms": 180000
      },
      "metadata": {"category": "persistence"}
    }
  ]
}
```

Paths are relative to the manifest. Commands are executed directly, never
through an implicit shell. A manifest can explicitly run `sh -c`, but doing so
is a choice to execute shell code, not a parsing convenience hidden by the
runner.

The default workspace strategy copies the task directory for every attempt
and initializes each copy as its own Git repository, so a `git commit` the
agent runs inside a copy stops there instead of reaching an enclosing
repository. Large repositories should pass a workspace callback backed by
Git worktrees, filesystem snapshots or another host-owned mechanism:

```elixir
workspace = fn task, %{attempt: attempt, runtime: runtime} ->
  MyHost.Worktrees.checkout(task, attempt: attempt, runtime: runtime)
  #=> {:ok, task_with_new_cwd, cleanup_zero_arity_fun}
end
```

## Runtimes

The native runtime uses the public embedding API. Provider credentials remain
in provider configuration and are never copied into the manifest or report:

```elixir
alias Lemieux.Benchmark
alias Lemieux.Benchmark.Runtime
alias Lemieux.Benchmark.Runtime.Command
alias Lemieux.Benchmark.Runtime.Native
alias Lemieux.Providers.ReqLLM

{:ok, _apps} = Application.ensure_all_started(:req_llm)

native =
  Runtime.new("native", Native,
    provider: ReqLLM.new(),
    model: "anthropic:claude-sonnet-5",
    session_options: [max_turns: 40, max_cost_usd: 5.00]
  )

wrapped =
  Runtime.new("wrapped", Command,
    command: ["claude", "-p", "--model", "claude-sonnet-5", "{prompt}"],
    timeout_ms: :timer.minutes(10)
  )

{:ok, report} =
  Benchmark.run_file("bench/manifest.json", [native, wrapped],
    repetitions: 3,
    output: "bench/results/run.json",
    workspace: workspace
  )
```

`:repetitions` defaults to 1. `:max_concurrency`, the number of attempts in
flight at once, also defaults to 1; the cost admission below works per
batch of that size.

`Command` is deliberately generic. Subscription authentication, verified CLI
versions and provider-specific flags belong to the host which owns that
runtime. `{prompt}`, `{cwd}` and `{task_id}` placeholders are substituted in
individual arguments without invoking a shell.

A custom runtime implements one callback:

```elixir
@behaviour Lemieux.Benchmark.Runtime

@impl true
def run(task, options) do
  {:ok, %{
    "status" => "completed",
    "answer" => "...",
    "usage" => %{"cost_usd" => 0.42}
  }}
end
```

Observations must be JSON-shaped. Runtime failures are recorded as failed
attempts rather than aborting the suite.

## Report and paired comparison

The schema-version-one report contains the manifest metadata, every runtime
observation, grader stdout and exit status, and summaries by runtime. Pair
summaries match attempts by task id and repetition, then report wins, losses,
ties and right-minus-left deltas for completion, wall time and cost.

`execution.actual_cost_usd` is the sum of *known* attempt costs. When
`execution.unknown_cost_runs` is positive, that number is an observed subtotal,
not the campaign's billed total; even `0.0` then leaves total cost unknown.
Per-runtime mean cost and paired cost deltas are null where comparisons cannot
be measured. Preserve frozen scores and any same-answer rescore separately;
record grader corrections instead of silently replacing campaign scores.

Runtime order rotates deterministically between attempts. This prevents a warm
filesystem or a transient provider slowdown from always favouring the same
runtime while keeping the artifact straightforward to reproduce.

Paid callers may pass `:max_cost_per_attempt_usd` with `:cost_cap_usd`. Before
each concurrent batch, the runner admits only the number of attempts whose
worst-case reservations fit beside measured spend, then reports reserved and
released dollars in `execution`. The standalone live evaluation command derives
that reservation from the per-candidate session cap. A host scheduler must
refuse unknown prices rather than omit the reservation and call the run safe.

The JSON report is an audit artifact, not a dashboard. Keep raw reports; derive
charts and confidence intervals outside the library so presentation choices do
not become runtime dependencies.

## A fair coding-agent evaluation

Use 10–20 tasks drawn from work the host actually performs. Prefer tasks with
mechanical pass/fail gates: focused tests, compilation, a repository precommit
alias, or a checked output file. Include failures the incumbent harness has
encountered rather than only greenfield demonstrations.

Hold constant:

- model and reasoning effort;
- system and workspace instructions;
- tool policy and sandbox;
- starting repository revision;
- context limits and maximum turns;
- prompt text;
- provider region/account where practical.

Run multiple repetitions and compare completion rate first. Wall time and cost
matter only among runs that produce acceptable work. Report cache-read and
cache-write tokens separately where the provider supplies them. Never count an
unknown price as zero.

### Evaluating delegated investigations

The subagent design has a stricter gate: compare the same native parent and
model with delegation disabled and with one to three read-only scouts enabled.
Keep the combined parent-plus-tree cost ceiling equal to the baseline ceiling,
rotate run order, and use repository snapshots that cannot be mutated by the
children. Include read-heavy tasks with hidden ground truth for call-site
recall, root-cause ranking, missing-test discovery, and completed-diff review.

The native runtime reports `usage` as the inclusive parent-plus-child total;
`usage.direct` and `usage.delegated` retain the split. This makes the design's
three-times-token ceiling auditable in the ordinary benchmark artifact. Use a
mechanical grader for the resulting patch and score factual precision/recall
and child-envelope fact retention from the recorded answers and transcripts.

After one prompt/schema tuning pass, keep the feature only if it produces at
least a 15-point absolute grounded-correctness/recall gain or a 30% wall-clock
reduction at equal quality, while consuming no more than three times the
tokens, making zero unauthorized writes, and losing critical child facts in
fewer than 5% of runs. The library supplies comparable observations; a host
must supply its representative corpus, ground truth, credentials, repetitions,
and scoring policy.

### Evaluating tool profiles

Represent each strategy arm as a separate native runtime whose
`session_options` set `tools`, `tool_profile` and, when available, an exact
`tool_token_counter`. Keep the provider/model and all non-tool options equal.
Declare the arms and decision thresholds before running. The executable
contract is documented in [Governed tool contracts](tool-contracts.md).

A native observation whose attempt ended on a provider failure carries
`provider_error` at its top level: the failure's `category` (`timeout`,
`server`, `rate_limit`, `context_limit`, `refused` or `other`, as
`Lemieux.Provider.Error.category/1` files it), its `reason` as a sentence, its
`http_status` and the provider's own `code` (each `null` when the failure had
none). A `retry: [max: n, when: predicate]` option to
`Lemieux.Benchmark.run/3` reads them to tell the apparatus failing from the
model failing; the status is there so a predicate can retry a gateway's bare
`414` once without retrying every `other`. `refused` is a request the
provider declined on policy grounds (a code such as `cyber_policy`, or an
answer its filter stopped), which a predicate should not retry: it is
usually refused again, and each attempt is another flagged request on the
account.

Native observations include `tool_metrics`: catalog bytes and exact tokens
when supplied, tokenizer names, calls, errors, denials, unavailable calls,
timeouts, output bytes, declared external cost, descriptor digests and profile
ids. Runtime summaries include mean input/output tokens, catalog bytes/tokens,
calls and errors. This supports the four-core, interactive, focused-Elixir,
combined, curated and MCP disclosure comparisons without embedding a customer
corpus or provider tokenizer in Lemieux.

## What this does not claim

- Model execution is nondeterministic. The runner makes inputs comparable; it
  does not make outputs repeatable.
- A command grader is arbitrary code with the launching user's authority.
- Copying a directory is isolation between attempts, not a security sandbox.
  `Lemieux.Benchmark.Runtime.Sandbox` validates host-issued image/repository
  digests, changed paths, violations, and signed attestations for safety-scoped
  runs; it does not provision or impersonate the missing microVM service.
- A 100-request cache-retention run is an opt-in live benchmark, not suitable
  for ordinary package CI.
- A host's workflow outcomes, merge-queue behavior and subscription economics
  need that host's own corpus and reporting layer.

## Agent extension workbench

Use `mix lemieux.extension.workbench bench/workbench.exs` to define cases,
compare named agent variants, and inspect failures. Model/effort search and
quota-backed request limits share the same runner. See
[agent extensions](agent-extensions.md) for configuration and
[confirmation](agent-extensions.md#confirmation-and-qualified-export) for independent frozen evaluation.

`Benchmark.Resources` joins each direct request to its response, including
compaction, and reports complete totals separately from observed lower bounds.
Cache inputs are counted once. All-attempt resources per success include failed
attempts; absent spend is not zero. Timeout observations retain partial work.
The Agent runtime requires normal completion before grading, while historical
Native runtime acceptance remains artifact-oriented. Compare like with like.

## Recorded results

Dated results the examples point to. Each is evidence about the models, corpus
and code of its date; rerun it before relying on it anywhere else.

### Verifier pipeline, 2026-09-17

The [verifier example](https://github.com/houllette/lemieux/blob/main/examples/extensions/verifier/README.md)
wraps a coding session in a pipeline: after the change it runs the project's
own check, and if the check fails it retries once with the failure. Its
`bench/compare.exs` compares `plain` (an ordinary `Lemieux.Agent.Session`)
with `verifier` on four cases from `eval/corpus/discovery-v1`.

To run it again, work from `examples/extensions/verifier` in a checkout of
this repository, with the provider's key in the environment, and name the
model to compare on; there is no default. Run every command in the same
shell: `LEMIEUX_EXTENSION_BASE` points the example at your checkout, and
without it the example uses the `lemieux` release from Hex. The comparison is live, so it spends that provider's money or
quota:

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix deps.get
LMX_MODEL=provider:model mix lemieux.extension.eval bench/compare.exs --allow-live
mix run bench/summarize.exs tmp/verifier-report.json
```

Each session is capped at 24 requests. A verifier attempt runs at most two
sessions (the task and one retry), so it can make up to 48 requests, where a
plain attempt makes up to 24.

The retained result: two repetitions per case per arm, sixteen attempts per
model, concurrency 2. Each run writes the configuration's
`tmp/verifier-report.json`; the two reports were renamed by hand to
`tmp/verifier-report-glm.json` and `tmp/verifier-report-luna.json`.
`mix run bench/summarize.exs REPORT` prints the tables. Passed and Retries
count attempts; Requests, Input tokens, Output tokens and Wall time are
per-attempt means over the two repetitions.

GLM-5.3 (`zai_coding_plan:glm-5.3`, quota), per-attempt means:

| Case | Arm | Passed | Retries | Requests | Input tokens | Output tokens | Wall time |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `edit-existing-file` | plain | 2/2 | n/a | 5 | 5059 | 135 | 22s |
| `edit-existing-file` | verifier | 2/2 | 0 | 5 | 5670 | 153 | 19s |
| `receipt-two-decimals` | plain | 1/2 | n/a | 11 | 33214 | 1616 | 39s |
| `receipt-two-decimals` | verifier | 2/2 | 0 | 10 | 25516 | 1264 | 62s |
| `shell-pipeline-status` | plain | 0/2 | n/a | 5 | 13832 | 3841 | 143s |
| `shell-pipeline-status` | verifier | 2/2 | 0 | 10 | 30487 | 6872 | 211s |
| `slugify-locked-tests` | plain | 1/2 | n/a | 7 | 21493 | 2819 | 93s |
| `slugify-locked-tests` | verifier | 2/2 | 0 | 6 | 12982 | 1021 | 37s |

gpt-5.6-luna (metered, about $0.05 for the run), per-attempt means. The
retained record names the model but not the provider route it was reached
through, so a rerun names one:

| Case | Arm | Passed | Retries | Requests | Input tokens | Output tokens | Wall time |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `edit-existing-file` | plain | 1/2 | n/a | 3 | 2388 | 90 | 20s |
| `edit-existing-file` | verifier | 1/2 | 0 | 3 | 2073 | 79 | 19s |
| `receipt-two-decimals` | plain | 2/2 | n/a | 7 | 13086 | 909 | 17s |
| `receipt-two-decimals` | verifier | 2/2 | 1 | 8 | 17674 | 992 | 38s |
| `shell-pipeline-status` | plain | 1/2 | n/a | 5 | 13167 | 1684 | 40s |
| `shell-pipeline-status` | verifier | 2/2 | 0 | 6 | 12629 | 2295 | 34s |
| `slugify-locked-tests` | plain | 2/2 | n/a | 5 | 8756 | 662 | 13s |
| `slugify-locked-tests` | verifier | 2/2 | 0 | 5 | 9768 | 671 | 14s |

How to read it. The headline pass rates (GLM plain 4/8 against verifier 8/8;
Luna plain 6/8 against verifier 7/8) overstate the pipeline. Every plain
failure but one was a provider request timeout that ended the session with
`finish_reason: :error` before any fix was attempted, and one GLM plain
attempt failed in zero seconds because two workers raced to mount the runtime
(fixed in `Lemieux.Agent.Session` the same day). Those are infrastructure
failures the pipeline happened not to draw, not wrong fixes it caught. The
evidence for the pipeline itself is narrower and real: on GLM the project
check passed first time in all eight verifier attempts, so the retry never
fired and the check cost about ten percent more tokens; on Luna the check
failed once (`receipt-two-decimals`, where the second call site was left
broken), the one bounded retry fixed it, and the final check and the external
grader both passed. One retry in sixteen verifier attempts is the measured
rate at which these two models leave a project check failing on this corpus.

What would make the number bigger: cases where a first pass more often fails
the project's own check (weaker models, larger repositories), and an
evaluation lane that retries provider timeouts the way the discovery lane
retries incomplete attempts, so the comparison is between fixes and not
between lucky draws.

## Measuring test-suite performance

This section is for contributors measuring Lemieux's own test suite. Record
the source revision, suite size, platform and toolchain with every
measurement. Measure the ordinary suite separately from `--slowest` profiling,
which can change tracing and concurrency. Do not add serial component savings
as if they were parallel wall-time savings.

Keep real timeout assertions and global-state tests serial. Prefer
readiness, state and exit signals to sleeps. Investigate reproducible races
without weakening assertions, exclusions or coverage thresholds. Linux
process-exit behavior needs Linux evidence.
