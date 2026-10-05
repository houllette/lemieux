# Failure-capture extension

- **What it shows:** a `session_end` hook that turns a session which failed
  its own tests, or was corrected by the person, into a draft evaluation case.
- **Runs offline?** Yes. The hook itself makes no model call, and
  `mix test` (no key) builds transcripts directly and runs one scripted
  session.
- **Needs:** `lmx` (or a source checkout) and whatever model your sessions
  already use. The command-hook variant also needs this project compiled once.

This extension turns ordinary `lmx` sessions into draft evaluation cases, so
the self-improvement corpus grows from daily use instead of by hand. It is a
`session_end` hook: when a session ends it reads the finished transcript and,
if either of two signals fired, records a feedback record, freezes the
workspace as a bounded fixture and prints one line saying where the draft is
and how to promote it. It never promotes, never edits a corpus, never blocks
a session, and is silent when neither signal fired.

The two signals:

- **Verification failure.** A `bash` call whose command contains one of the
  verification patterns (`mix test`, `tests/run.sh`, `make test`,
  `make check`, `npm test`, `pytest`, `cargo test`, `go test`) exited
  non-zero, and no later matching command in the session exited zero. The
  draft is a `mechanical` case whose grader is `sh -c COMMAND` over the
  frozen workspace, written through `Lemieux.Feedback.CaseDraft`.
- **Correction.** A user message after at least one assistant turn that opens
  with a correction pattern (`no`, `wrong`, `that's not`, `undo`, `revert`,
  `not what I asked`, `you broke`; whole words, any case). There is no
  verifier yet, so the draft is a *review draft*: the same layout, marked
  `needs_review`, with no task — which is what makes `lmx corpus promote`
  refuse it until a person has classified it.

A session with both gets the mechanical draft; the correction stays in the
feedback record as evidence. Everything about the draft is beside it:
`draft.json`, the `fixture/`, and `capture.json` with the signals, the
snapshot bounds and every path the snapshot skipped.

## What it writes

```text
~/.lmx/feedback/fb_ID.jsonl          the feedback record, as `lmx feedback` writes it
.lmx/drafts/.gitignore               `*`, written once, so `git add -A` never stages a draft
.lmx/drafts/case_ID/fixture/         the workspace at session end, bounded
.lmx/drafts/case_ID/draft.json       the draft record (`task` only for mechanical drafts)
.lmx/drafts/case_ID/capture.json     signals, snapshot summary, skipped paths, promote command
```

A `.gitignore` already in the drafts directory is left as it is. Drafts reach
a corpus through `lmx corpus promote`, not by being committed where they were
written.

The fixture skips `.git`, `_build`, `deps` and `node_modules` at any depth,
files over 1 MiB, anything past 16 MiB in total, symlinks, and the drafts
directory itself. It also never copies files named like credentials, in any
letter case: `.env` and `.env.*` (only the `.env.example` template is kept),
`.envrc`, `mise.local.toml`, private keys and certificate bundles (`*.pem`,
`*.key`, `*.p8`, `*.p12`, `*.pfx`, `*.ppk`, `*.jks`, `*.keystore`, SSH keys
such as `id_rsa*` and `id_ed25519*`), credential stores (`.netrc`, `_netrc`,
`.npmrc`, `.pypirc`, `.pgpass`, `.git-credentials`, the AWS `credentials`
file, `*credentials*.json`, service-account and `client_secret*.json` keys),
`*.secret.exs`, `erl_crash.dump`, and `lmx`'s own `.lmx/config.json`, where
it saves provider keys. These are the names Lemieux itself leaves out when it
copies a workspace into a corpus. Each skip is recorded with its reason
(`secret` for those), because a fixture missing a file is one whose grader
may fail for the wrong reason.

## Enabling it

`docs/hooks.md` gives hosts two ways to attach a hook: an Elixir host passes
functions in `:hooks`, and `lmx --hooks FILE` loads external commands. This
extension supports both, and a `mix run` entry point for source checkouts.
All three read the same transcript through the sessions directory.

### A prebuilt `lmx`: the command hook

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
export LMX_CAPTURE_HOME="$LEMIEUX_EXTENSION_BASE/examples/extensions/capture"
(cd "$LMX_CAPTURE_HOME" && mix deps.get && mix compile)   # once

lmx --hooks "$LMX_CAPTURE_HOME/hooks.json"
lmx run --hooks "$LMX_CAPTURE_HOME/hooks.json" "make the tests pass"
```

From a source checkout without an installed `lmx`, run the same commands
from the Lemieux root as `mise exec -- mix lmx -C /path/to/your/project ...`.
`-C` makes the project the session's working directory, so drafts land in
its `.lmx/drafts`, not in the Lemieux checkout.

`hooks.json` routes `sessionEnd` to `bin/capture`, which runs
`CaptureExtension.Command` under `mix run` with the hook's JSON on stdin.
The command protocol parses stdout as JSON and shows stderr only when a hook
fails, so under this variant the one-line report cannot reach your terminal:
it is appended to `.lmx/drafts/capture.log` instead, and stdout carries
`{"draft": ..., "feedback_id": ..., "class": ..., "promote": ...}` for
anything reading the hook. Configure it with the `env` object of the hook
entry or your shell: `LMX_CAPTURE_DRAFTS_DIR`, `LMX_CAPTURE_FEEDBACK_DIR`,
`LMX_CAPTURE_VERIFICATION_PATTERNS` and `LMX_CAPTURE_CORRECTION_PATTERNS`
(`|`-separated), `LMX_CAPTURE_MAX_FILE_BYTES`, `LMX_CAPTURE_MAX_TOTAL_BYTES`,
`LMX_CAPTURE_TENANT_ID`; `LMX_SESSIONS_DIR` is `lmx`'s own.

Lemieux never discovers a hook file on its own: pass `--hooks` explicitly,
every time, as `docs/hooks.md` says.

### A source checkout: `mix run`

```sh
cd examples/extensions/capture
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix deps.get
mix run -e 'CaptureExtension.lmx(System.argv())' -- run "make the tests pass"
```

`CaptureExtension.lmx/2` is `Lemieux.CLI.run/2` with the Elixir hook
attached. It honours `--sessions-dir` and still loads a `--hooks FILE`. The
report line lands on stderr, after the answer. The full-screen TUI needs the
optional `ex_ratatui` dependency, which this example does not declare; use
the command hook with a prebuilt `lmx` for that.

### An embedding host

```elixir
Lemieux.start_session(
  provider: provider,
  store: store,
  model: model,
  hooks:
    CaptureExtension.hooks(
      sessions_dir: sessions_dir,
      drafts_dir: "eval/drafts",
      verification_patterns: ["mix test", "mix precommit"]
    ) ++ my_hooks
)
```

`hooks/1` takes `CaptureExtension.Config.new/1`'s options: the two pattern
lists, `drafts_dir` (relative to the session's working directory),
`sessions_dir`, `feedback_dir` (default: the `feedback` directory beside the
sessions directory, as `lmx feedback` uses), `max_file_bytes`,
`max_total_bytes`, `skip_dirs`, `tenant_id`, and `store` / `feedback_store`
for a host that owns its persistence. Invalid options raise when the hook is
built, not at session end.

## Reviewing a draft

A mechanical draft is ready for the ordinary review:

```sh
lmx corpus promote .lmx/drafts/case_ID eval/corpus/local/manifest.json \
  --cluster CLUSTER --allow lib/value.ex
```

A review draft needs a person first. Decide whether the correction is
mechanically verifiable, write the verifier, then classify and re-draft from
the frozen fixture with the printed command:

```sh
lmx feedback draft-case FB_ID --source .lmx/drafts/case_ID/fixture --output eval/drafts \
  --prompt "..." --verifier "sh check.sh" --class mechanical
lmx corpus promote eval/drafts/case_ID eval/corpus/local/manifest.json --cluster CLUSTER
```

Read `capture.json` before either: it lists what the snapshot left out. Then
check the fixture itself for credentials before promoting. The name rule above
catches the usual files, not a key pasted into an ordinary source file, and a
promoted fixture is meant to be committed.

## Tests

```sh
cd examples/extensions/capture
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix test
```

The tests build transcripts directly and run one real session against
`Lemieux.Providers.Scripted`; nothing needs a model or a key.
