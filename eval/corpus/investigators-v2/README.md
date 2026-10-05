# Investigators corpus v2

Thirty read-only investigation questions whose fixtures are too large to
read in one tool call and whose facts are scattered across directories.
Built for the read-only delegation experiment in
[`docs/subagents.md`](../../../docs/subagents.md#evaluation-gate)
after [`investigators-v1`](../investigators-v1/README.md) tied 30/30 on
both arms: a parent holding `bash` reads a twelve-file fixture in one or two
commands, so v1 never tested whether investigator children help.

The manifest is the same version-1 schema as `../v1/manifest.json`
(`Lemieux.Benchmark.Manifest`). Every case forbids `write` and `edit`,
requires `read`, allows no changed paths, and carries the `investigators`
and `v2` tags. Nothing is written; the agent reports back and the fixture's
`check.sh` grades the reply.

## What makes a fixture "too large"

The `bash` tool truncates output at 30,000 bytes
(`lib/lemieux/tools/bash.ex`); the `read` tool at 60,000 bytes or 2,000
lines (`lib/lemieux/tools/read.ex`). Every fixture here is at least 250 KB
across at least 40 files in at least 6 directories nested two or more
levels deep, and every fixture holds at least one file over 30 KB, so no
single `cat`, `grep -r`, `find` or `head` can surface the answer inside one
truncated output. Fixtures run 276 KB to 487 KB; the corpus is about
10.6 MB.

Every answer joins at least four facts from at least four directories
through at least two indirections (an id that maps to another id that maps
to a name; a config key whose value names a file whose contents name a
host; a log line whose session id appears in a second log under a different
field name). Every case has at least three decoys that, read alone, give a
different answer; they are named in `metadata.notes`, which the agent never
sees. A `grep` for the words in the question returns either nothing useful
or dozens of hits.

## Clusters

`metadata.cluster_id` groups five cases that exercise the same kind of
cross-file reasoning. Cases in a cluster are not independent samples; count
a cluster as one unit of evidence.

| Cluster | What the answer requires | Cases |
| --- | --- | --- |
| `log-join` | Joining hour- and day-sharded logs on request, session, connection, run and object ids through host, service, device, principal, tenant and storage inventories, under README rules about origins, retries, recycled ids and superseded runs. | `logjoin-error-ref-user-host`, `logjoin-slowest-query-service`, `logjoin-lockout-device`, `logjoin-first-5xx-build`, `logjoin-export-failure-object` |
| `config-layering-large` | Resolving a deployment target through a profile inheritance chain, includes spliced at their position, overlays in listed order, an environment layer, locked policy keys, sink files and `${VAR}` substitution, across about 130 files. | `cfglarge-request-timeout-prod-eu`, `cfglarge-locked-pool-size`, `cfglarge-overlay-order-variant`, `cfglarge-log-sink-hostname`, `cfglarge-cert-path-vars` |
| `call-graph-large` | Following an entry point through a registry table, a binding or settings file and a resolved class to the function that does the work, in a 140-file codebase with same-named decoys in legacy and sibling modules. | `callgraph-cli-export-audit-writer`, `callgraph-event-refund-writer`, `callgraph-http-invoice-template`, `callgraph-scheduler-reconcile-digest`, `callgraph-signal-quota-pager` |
| `data-join-large` | Joining CSV, JSON and NDJSON shards under README rules: statuses, refunds, currency conversion and region groups; dated catalog rows; dated tier history; dated reporting lines; calibration offsets and a mid-week threshold change. | `datajoin-top-emea-customer`, `datajoin-sku-missing-from-catalog`, `datajoin-order-total-after-discount`, `datajoin-skip-level-manager`, `datajoin-sensor-breach-count` |
| `deps-and-build-large` | Reconciling fictional `.deps` manifests, per-profile `.lock` directories, vendored and forked copies, workspace replacements, image build arguments and include-path rule files. No real package-manager file names appear, so nothing is scanned as a dependency. | `depslarge-workspace-replace-version`, `depslarge-lock-profile-pin`, `depslarge-image-tool-version`, `depslarge-transitive-source`, `depslarge-include-path-vendor` |
| `docs-vs-code-large` | Reporting what the code does where a large documentation tree says otherwise: a status code from an error table, a header name and unit from a headers file, a signing profile, a clamped default, an exit table. | `docslarge-duplicate-email-status`, `docslarge-rate-limit-reset-header`, `docslarge-webhook-signature-algo`, `docslarge-default-page-size`, `docslarge-cli-exit-partial` |

`metadata.minimum_files` records how many fixture files must be read to
answer with confidence (five to seven for every case); `fixture_files` and
`fixture_bytes` record the fixture's size and are checked for staleness by
the test.

## Layout

- `repos/<case-id>/` is the fixture the agent works in, including its
  `check.sh`. The script pins every fixture file by `cksum`, lowercases the
  reported answer and requires each expected token (a value, an identifier,
  a file path; a few accept a synonym such as `millisecond` / ` ms`). It
  fails on an empty answer and on any answer missing a token. Because the
  script lives where an agent can read it, the tokens are stored as
  octal-escaped `printf` strings and the failure messages only number the
  missing fact. Graders never touch the network and run in well under a
  second.
- `answers/<case-id>.txt` holds a passing reference answer, with the
  reasoning that reaches it. It proves the grader is satisfiable and is
  never shown to an agent.
- `manifest.json` lists every case with `cluster_id`, `tags`,
  `required_tools`/`forbidden_tools`, `minimum_files`, `fixture_files`,
  `fixture_bytes`, `notes` and an empty `safety.allowed_changed_paths`.
- `generators/` holds the Python 3 scripts (standard library only) that
  produce everything except this README. `python3
  eval/corpus/investigators-v2/generators/build.py` rewrites `repos/`,
  `answers/` and `manifest.json` byte for byte; every generator is seeded
  per case. The generators compute each answer by applying the README rules
  of the fixture to the generated data (the config cluster runs a resolver,
  the data cluster the aggregation) and assert that every planted decoy
  gives a different value, so a change to a rule that silently changed an
  answer fails the build rather than the grader.

`test/lemieux/benchmark/investigators_v2_corpus_test.exs` copies every
fixture to a temporary directory and checks that the grader passes the
untouched fixture with the reference answer, fails with an empty answer,
fails with a reply that names no fact, that the metadata above is complete
and not stale, and that every fixture meets the size floor described above.

## Grading conventions

A token check is deliberately a substring match on the lowercased reply, so
an answer may explain the layers it rejected (the reference answers do). It
is not a negative check: naming the right value and a wrong one in the same
reply passes. Where a value is a number the generator asserts that no decoy
value contains the right one as a substring (`152` against `150`, `190`,
`191`; `118.30` against `105.50`, `140.80`, `137.58`).

## Adding a case

1. Add a `case_*` function to the cluster's generator (or a new generator
   registered in `build.py`). Plant the story on top of the world builder,
   compute the answer from the rules rather than writing it down, and
   assert that each decoy differs. `common.validate` refuses a case under
   250 KB, under 40 files, under 6 directories, without a nested directory,
   without a file over 30 KB, with a prompt of 400 characters or more, or
   whose prompt does not say to report back without changing any files.
2. Name the decoys in `notes`; keep the prompt free of the words `grader`,
   `solution` and `check.sh`.
3. Run `build.py`, then the grader three ways from the fixture directory:
   with the reference answer (must pass), with `""` (must fail) and with a
   reply that names no fact (must fail).
4. Run `mix test test/lemieux/benchmark/investigators_v2_corpus_test.exs`.
5. Never use a real package-manager file name (`package.json`, `go.mod`,
   `Cargo.toml`, `mix.lock`, `requirements.txt`, ...) inside a fixture:
   GitHub's dependency graph scans them and raises alerts for pins that
   nothing installs. Use the fictional `.deps` / `.lock` formats.
