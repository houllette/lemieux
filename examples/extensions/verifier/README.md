# Verifier pipeline extension example

- **What it shows:** a pipeline around a coding session: run the project's own
  tests after the change, and retry once with the failure when they fail.
- **Runs offline?** Yes. `mix test` runs every stage against a scripted model,
  with no key.
- **Needs:** for its live comparison, `LMX_MODEL` and that provider's key; for
  live use from a host, the host's provider and model.

This is a native **extension**: an ordinary Mix library that starts nothing on
its own. It runs one bounded coding session, discovers the repository's own
verification command from its conventions, runs that command with a deadline
and an output cap, and on failure runs exactly one retry session whose prompt
carries the failing command and a bounded excerpt of its output. Everything is
ordinary Elixir around two `Lemieux.Agent.Session` calls; there is no pipeline
DSL and no second agent loop.

## Why

The most common way agent runs went wrong in Lemieux's own harness-discovery
campaigns was "changed it, never checked it" (the `verify-after-change`
cluster of the discovery corpus). Its canonical case, `receipt-two-decimals`
in `eval/corpus/discovery-v1`, has an obvious fix that leaves a second call
site which only the project's own test run reveals. A system-prompt line
asking the model to verify is advice it can ignore. Making the check a
pipeline stage is not.

## What runs

1. **Task session.** The host's prompt, tools and profile, unchanged. The
   first attempt is exactly the session a plain agent would run.
2. **Discovery** (`VerifierExtension.Discovery`), in this order, first match
   wins: an explicit `verify_command` option; `tests/run.sh` (run with `sh`);
   a `Makefile` with a `test` target, then a `check` target; `mix.exs`
   (`mix test`); `package.json` with a real `scripts.test` (`npm test`).
   With no match the result says `discovered_from: nil`, no check runs and
   there is no retry.
3. **Check** (`VerifierExtension.Check`), through `Lemieux.Environment` so a
   host that relocates tool execution gets its check run there too. Bounded
   by `verify_timeout_ms` (default two minutes) and `verify_output_bytes`
   (default 16 KiB, head and tail kept). Every ending is named: `passed`,
   `failed`, `timed_out`, `output_limit` or `failed_to_run`.
4. **One retry**, only if the check did not pass and time remains on the
   input's `timeout_ms`. Its prompt repeats the task, names the command and
   how it ended, quotes the last `verify_excerpt_bytes` (default 4 KiB) of
   output, and forbids editing tests or the check. Then the command runs once
   more.

**`check.sh` is never discovered.** In this repository's corpus it is the
external grader; a verifier that ran it would be reading the answer key and
its pass rates would measure grader satisfaction, not self-verification. The
corpus prompts never mention it, discovery never proposes it, and the retry
prompt never names it. A project that genuinely uses a `check.sh` as its test
entry point passes it as `verify_command`.

The pipeline never edits a file itself. Whether the retry honoured the ban on
touching tests is recorded as `retry_changed_tests` rather than enforced:
silently reverting the model's work would hide the one fact a reviewer most
needs.

## Result shape

`run/2` returns a completed observation whenever the last session completed.
A failed final check is data, not an agent failure; the external grader is
the arbiter in a benchmark, and a host that wants to gate on the check reads:

```elixir
%{
  "status" => "completed",
  "answer" => "...",                 # the last session's answer
  "session_id" => "...",             # the last session
  "session_ids" => ["...", "..."],   # task, then retry when one ran
  "sessions" => [%{"role" => "task", ...}, %{"role" => "retry", ...}],
  "transcript" => [...],             # every session's entries, in order
  "usage" => %{...},                 # summed over sessions; nil cost stays nil
  "verification" => %{
    "command" => "sh tests/run.sh",
    "discovered_from" => "tests/run.sh",   # or "verify_command", "Makefile", ...
    "first_status" => "failed",
    "retry?" => true,
    "final_status" => "passed",
    "runs" => [%{"status", "exit_status", "output", "duration_ms", ...}, ...],
    "retry_changed_tests" => []
  }
}
```

`usage`, `resources` and `tool_metrics` cover every session
(`VerifierExtension.Totals`), so a benchmark's per-attempt accounting sees the
whole composition. A cumulative deadline from the input's `timeout_ms` bounds
both sessions; the retry is skipped when nothing remains.

## Tests

From this directory, with an absolute path to your Lemieux checkout:

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix deps.get
mix test --warnings-as-errors
```

The tests are offline (`Lemieux.Providers.Scripted`). `test/fixtures/ledger`
is a shell-only replica of the corpus case: two renderers share a bug, a
scripted first session fixes one, the fixture's `tests/run.sh` fails on the
other, the scripted retry fixes it and the final run passes. Other tests cover
a passing first run (no retry), a workspace with nothing to discover, an
explicit `verify_command`, a check that outruns its deadline, a retry that
edits the tests, a session that never completes, discovery precedence, and
output bounding. The fixture carries a decoy `check.sh` that must never run.

## Comparison

`bench/compare.exs` compares `plain` (`Lemieux.Agent.Session`) against
`verifier` on four corpus cases referenced in place from
`eval/corpus/discovery-v1`: `receipt-two-decimals` (the case this was built
for), `shell-pipeline-status` and `slugify-locked-tests` (fixtures with a
`tests/run.sh`), and `edit-existing-file` (nothing to discover, so the arms
must tie). Both arms configure their sessions from `VerifierExtension.profile/2`,
the base coding profile the discovery campaigns run, so the pipeline is the
only difference. Graders are the corpus check scripts; the benchmark runs
them and the agent is never shown them.

This is live execution: it spends the selected provider's money or quota.
Set `LMX_MODEL` to the model to compare on; there is no default. Keys stay in
the process environment, and the provider is `Lemieux.Providers.ReqLLM.new()`,
never a personal `~/.lmx/config.json`:

```sh
set -a; . /path/to/.env; set +a
export LMX_MODEL=provider:model
mix lemieux.extension.eval bench/compare.exs --allow-live
mix lemieux.extension.workbench bench/compare.exs
```

`VERIFIER_REPETITIONS` (default 2) sets the repetitions per case and arm. The
plan is 4 cases × 2 arms × repetitions attempts. Each session may make at most
24 requests, and a verifier attempt runs at most two sessions (the task and
one retry), so it can make up to 48 where a plain attempt makes up to 24. The
budget is in requests, not dollars. Reports and session transcripts land under
`tmp/`, which this example ignores, and
`mix run bench/summarize.exs tmp/verifier-report.json` prints a per-case table. Development cases that have been exposed this way cannot serve
as hidden confirmation evidence; see the
[confirmation guide](../../../docs/agent-extensions.md#confirmation-and-qualified-export).
Recorded results are in [Benchmarking](../../../docs/benchmarking.md).

## Limits

- The check runs where the session's tools run, with the same permissions.
  This is not a sandbox; hosts that need isolation supply an environment.
- On a host without `setsid`, the local environment kills only the command's
  shell; a grandchild holding the output pipe is orphaned. The check still
  reports `timed_out` on time (the pipeline owns its deadline), but the
  orphan runs on, as it would under the session's own `bash` tool.
- `retry_changed_tests` is evidence, not enforcement, and matches paths under
  `test`, `tests`, `spec`, `__tests__` or named like test files.
- There is no `configure/1`, so this example has no frozen-evaluation profile
  yet. Its comparison is a development result, not a qualification.

## Using it from another Mix application

```sh
mix lemieux.extension.export . /tmp/verifier-extension-export
```

```elixir
{:verifier_extension, path: "/tmp/verifier-extension-export"}

Lemieux.Agent.run(VerifierExtension,
  %{prompt: "Fix the money formatting", cwd: "/path/to/repo", timeout_ms: 600_000},
  provider: provider,
  model: model,
  supervisor: MyHost.Lemieux,
  session_options: [max_turns: 24],
  verify_timeout_ms: 120_000
)
```

Outside this checkout the example depends on `lemieux` from Hex. For
development against this checkout, set `LEMIEUX_EXTENSION_BASE` to its
absolute path; unset it to use the Hex release. Export preserves `mix.exs` and
does not publish to Hex or install the extension into `lmx`.
