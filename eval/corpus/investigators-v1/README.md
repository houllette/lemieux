# Investigators corpus v1

Thirty read-heavy, report-only questions for the read-only delegation
experiment in [`docs/subagents.md`](../../../docs/subagents.md#evaluation-gate).
Each case is a small fixture (four to eleven files) and one precise question
whose answer is a value, an identifier or a file path that only falls out of
combining several of those files. Nothing is written; the agent reports back
and the fixture's `check.sh` grades the reply.

The manifest is the same version-1 schema as `../v1/manifest.json`
(`Lemieux.Benchmark.Manifest`). Every case forbids `write` and `edit`, allows
no changed paths, and carries the `investigators` tag.

## Clusters

`metadata.cluster_id` groups five cases that exercise the same kind of
cross-file reasoning. Cases in a cluster are not independent samples; count a
cluster as one unit of evidence.

| Cluster | What the answer requires | Cases |
| --- | --- | --- |
| `config-precedence` | Applying documented layering rules (YAML stages, TOML `inherits`, locked JSON flags, INI includes, a shell script's own precedence) across the files that participate. | `config-effective-log-level`, `config-profile-inherit-chain`, `config-locked-flag`, `config-ini-include-order`, `config-port-precedence-script` |
| `dependency-versions` | Reconciling manifests, lockfiles and build scripts: nested npm installs, a drifted `mix.lock`, an unsatisfiable pip constraint, a build arg sourced from `package.json`, a `go.work` replace. | `deps-nested-lock-version`, `deps-mix-lock-drift`, `deps-pip-constraint-conflict`, `deps-image-pnpm-version`, `deps-go-workspace-replace` |
| `call-graph` | Following a call chain across four or five files to the function that actually does the work, past a same-named or same-purpose decoy. | `callgraph-shell-sync-download`, `callgraph-python-error-renderer`, `callgraph-js-journal-writer`, `callgraph-elixir-unauthorized-response`, `callgraph-make-deploy-uploader` |
| `log-correlation` | Joining several logs on request ids, sessions, hosts, addresses or timestamps to name a root cause. | `logs-error-reference-query`, `logs-deploy-regression-version`, `logs-nightly-export-root-cause`, `logs-lockout-device`, `logs-search-latency-cache-node` |
| `contract-docs-code` | Reporting what the code does where the documentation says otherwise: error codes, headers and units, signature algorithms, clamped defaults, overridden exit statuses. | `contract-duplicate-email-code`, `contract-rate-limit-header`, `contract-webhook-signature`, `contract-default-page-size`, `contract-cli-exit-status` |
| `data-files` | Joining CSV and JSON files under the rules in a README: refunds and statuses, discontinued SKUs, tier discounts, dated transfers, readings in tenths of a degree. | `data-top-emea-customer`, `data-sku-missing-from-catalog`, `data-order-total-after-discount`, `data-skip-level-manager`, `data-sensor-breach-count` |

`metadata.minimum_files` records how many fixture files must be read to
answer with confidence; 28 of the 30 cases need three or more, and every case
has at least one file that, read alone, suggests a different answer. Those
decoys are named in each case's `metadata.notes`, which the agent never sees.

## Layout

- `repos/<case-id>/` is the fixture the agent works in, including its
  `check.sh`. The script pins every fixture file by `cksum`, lowercases the
  reported answer and requires each expected token (a value, an identifier, a
  file name; some accept a short list of synonyms such as `clock skew` /
  `clock drift`). It fails on an empty answer and on any answer missing a
  token. Because the script lives where an agent can read it, the tokens are
  stored as octal-escaped `printf` strings and the failure messages only
  number the missing fact; an investigator that lists the directory and reads
  everything (the smoke run's child did) sees no answer in plain text.
  Graders never touch the network and run in well under a second.
- `answers/<case-id>.txt` holds a passing reference answer, with the
  reasoning that reaches it. It is proof that the grader is satisfiable and
  is never shown to an agent.
- `manifest.json` lists every case with `cluster_id`, `tags`,
  `required_tools`/`forbidden_tools`, `minimum_files`, `fixture_files`,
  `notes` and an empty `safety.allowed_changed_paths`.

`test/lemieux/benchmark/investigators_corpus_test.exs` copies every fixture to
a temporary directory and checks that the grader passes the untouched fixture
with the reference answer, fails with an empty answer, fails with a reply that
names no fact, and that the metadata above is complete.

## Grading conventions

A token check is deliberately a substring match on the lowercased reply, so an
answer may explain the layers it rejected (the reference answers do). It is
not a negative check: naming the right value and a wrong one in the same reply
passes. Where a value is a small number the fixture's decoys are chosen so
that no plausible wrong value contains the right one as a substring (`15`
against `25`, `50`, `100`, `200`; `75` against `3`, `64`).

## Adding a case

1. Write the fixture so that the answer needs at least three files and at
   least one file read alone gives a different answer; record which files in
   the manifest entry's `metadata.notes`.
2. Write `check.sh` with the `cksum` pins of every fixture file and the
   octal-escaped token checks (never a token in plain text or in a message),
   then `answers/<id>.txt` containing every token.
3. Run the grader three ways from the fixture directory: with the reference
   answer (must pass), with `""` (must fail) and with a reply that names no
   fact (must fail).
4. Add the manifest entry with `cluster_id`, tags including `investigators`,
   `forbidden_tools: ["write", "edit"]`, an empty allowlist, `minimum_files`,
   `fixture_files` and `notes`, and a prompt that never mentions the check
   script.
5. Run `mix test test/lemieux/benchmark/investigators_corpus_test.exs`.
6. Keep any exact pin in a fixture manifest (`requirements*.txt`,
   `package-lock.json`, `mix.lock`, `go.sum`) above the published advisory
   ranges for that package. GitHub's dependency graph scans these files as
   if they were real dependencies and raises Dependabot alerts for
   vulnerable pins even though nothing installs them; the pip case pinned
   `urllib3==1.26.18` and drew 13 alerts before it was moved to 2.7.0. A
   fixture only needs the constraints to disagree, so choose versions that
   disagree without pinning anything vulnerable. Every fixture file's
   `cksum` is in its `check.sh`, so a changed file needs its new checksum
   there too, and the reference answer updating where it quotes the old
   line; step 5 fails with "FILE was modified" until both are done (a
   Dependabot fix merged without them broke `main`, 2026-10-06).
