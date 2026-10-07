# Contributing to Lemieux

Thanks for taking a look. This repository holds `lmx`, a terminal coding
agent, and Lemieux, the Elixir runtime it is built on. Outside help is
welcome. Bug reports with a small reproduction, documentation fixes, tests,
and reports of how a provider or model handles the tool loop are all useful.

You do not need an API key to contribute. The ordinary test suite runs
offline against a scripted model and costs nothing.

- **Questions and ideas:** [GitHub Discussions](https://github.com/houllette/lemieux/discussions).
  [Getting help](https://github.com/houllette/lemieux/blob/main/.github/SUPPORT.md)
  says where everything else goes.
- **Security problems:** never in a public issue. See [SECURITY.md](SECURITY.md).
- **Conduct:** everyone who takes part follows the
  [Code of Conduct](https://github.com/houllette/lemieux/blob/main/CODE_OF_CONDUCT.md).

## Your first contribution in 15 minutes

The times below were measured on a 14-core Apple Silicon Mac; a smaller
machine takes longer. They leave out installing Erlang and Elixir, which can
take a while when Erlang compiles from source.

### 1. Get the code and the toolchain

You need [mise](https://mise.jdx.dev/) (or asdf), `git` and `python3`;
[Prerequisites](#prerequisites) lists everything. Fork the repository on
GitHub, then:

```sh
git clone https://github.com/YOUR-NAME/lemieux.git
cd lemieux
mise install                  # the Erlang and Elixir pinned in .tool-versions
mise exec -- mix deps.get     # a few seconds; say yes if Mix offers to install Hex
```

The commands below start with `mise exec --`. If mise already activates the
pinned tools in your shell, you can drop it. With asdf, add its two plugins
first (`asdf plugin add erlang` and `asdf plugin add elixir`), run
`asdf install`, and drop the prefix.

### 2. Run lmx from your checkout

```sh
mise exec -- mix lmx --version   # the first run compiles everything: about 40 s
mise exec -- mix lmx explain     # what lmx would run with, without calling a model
mise exec -- mix lmx             # the terminal UI
```

`mix lmx` takes exactly the installed binary's arguments, so every `lmx`
command in the guides works with `mise exec -- mix lmx` in its place. Add
`-C PATH` to work on another directory, and `LMX_CONFIG=none` in front to
keep your personal `~/.lmx/config.json` out of a run. Mix prints compile
progress on standard output, so run `mise exec -- mix compile` once before
you redirect `mix lmx run …` into a file.

To chat with a real model, export a provider key in your shell, or copy
`.env.example` to `.env` and uncomment the lines you fill in. `mix lmx` run
from the repository root reads the checkout's own `.env`; the installed `lmx`
never reads one. A local model served by Ollama needs no key.

### 3. Run the tests near your change

```sh
mise exec -- mix test test/lemieux/cli/commands_test.exs      # one file
mise exec -- mix test test/lemieux/cli/commands_test.exs:40   # the test at line 40
```

The first test run compiles the test environment, which takes about 40
seconds. Tests mirror `lib/`: code in `lib/lemieux/cli/` is tested from
`test/lemieux/cli/`, and [Find the right layer](#find-the-right-layer) says
where each area lives.

### 4. Make the change, test first

Add or update a test that fails without your change, then make it pass.
Review looks for:

- a test that can fail. `assert is_map(result)` on a function that always
  returns a map proves nothing;
- `@doc` and a typespec with named arguments on public functions, such as
  `@spec fetch(user_id :: integer()) :: {:ok, t()} | {:error, term()}`;
- no compiler warnings, in `lib/` or in tests;
- `async: true` unless the test touches global state, such as named
  processes or the application environment;
- a quiet, patient test: a passing run prints only dots, so a test captures
  what it writes to standard error and waits for what it started to end,
  and a test that waits for an event takes `assert_receive`'s default
  timeout rather than a shorter one;
- design reasoning next to the code it constrains, in the `@moduledoc`, the
  `@doc` or a comment, saying what would go wrong under the obvious
  alternative.

[AGENTS.md](https://github.com/houllette/lemieux/blob/main/AGENTS.md) has the
full list. It is written so that coding agents follow it, and it is the style
guide for people too.

### 5. Run the whole suite, then the gate

```sh
mise exec -- mix test         # about 4,700 tests in about a minute
mise exec -- mix precommit    # the gate: it must exit 0
```

`mix precommit` runs CI's main checks locally: the dependency audits,
warnings-as-errors compilation, formatting, Credo, xref, the docs build, the
suite, Dialyzer, and the checks of the `dist/lmx` release host. The first run
takes about 3 to 5 minutes, because it compiles the test dependencies and
builds Dialyzer's cache; later runs take about 2. It needs network access for
the audits. `mix ci` runs the same gate without rewriting anything, as the
release workflow does. Two things to know:

- It **rewrites files**: it formats the code and regenerates the usage-rules
  block at the end of `AGENTS.md`. Commit what it changed.
- It **stops at the first failing step**, and its exit status is the result.

If a step cannot run on your machine, open the pull request anyway and say
which steps you skipped; CI runs all of them. The audits come first, so
without network access the gate stops before it compiles anything. Run the
main checks yourself instead, in the test environment as CI does:

```sh
export MIX_ENV=test
mise exec -- mix compile --warnings-as-errors
mise exec -- mix format
mise exec -- mix credo --strict
mise exec -- mix test --warnings-as-errors
mise exec -- mix dialyzer
unset MIX_ENV
```

### 6. Open the pull request

- Commit with your GitHub noreply address; [Commit addresses](#commit-addresses)
  shows how. The *Commit identities* check fails otherwise.
- Title the pull request and its commits in the
  [Conventional Commits](https://www.conventionalcommits.org/) style, such as
  `fix: ...`, `feat: ...`, `docs: ...` or `test: ...`.
- Fill in the template: what changed, why, and how you tested it. One
  behaviour change per pull request is the easiest to review.
- For a user-visible change, update the guide that describes the behaviour,
  and add a line under `## Unreleased` at the top of
  [CHANGELOG.md](CHANGELOG.md), adding that heading if the file has none.

GitHub holds the CI runs of a first-time contributor until a maintainer
approves them, so checks on your first pull request may take a while to
start.

## Prerequisites

| You need | Why |
| --- | --- |
| [mise](https://mise.jdx.dev/), or asdf with its `erlang` and `elixir` plugins | Installs the Erlang and Elixir versions pinned in `.tool-versions`. CI uses exactly these; other versions can format code or report Dialyzer warnings differently. |
| `git` 2.28 or newer | Test fixtures run `git init --initial-branch`. |
| `python3` | The suite's MCP servers and process fixtures are Python scripts, and so are the release-helper tests. Without it, `mix test` stops at once with one error. |
| `make` | The discovery corpus tests run graders that call it. |
| A `kill` executable | Process tests signal with it. On Debian-based images, install `procps`. |
| macOS or Linux, as a user other than root | CI tests on Linux, and a scheduled workflow tests macOS. Some tests rely on file permissions, which root ignores. On Windows, work inside WSL2. |
| `epmd` | Only for the multi-node suite, `mix test.distributed`. It ships with Erlang, and the alias starts it. |
| Network access | For `mix deps.get`, the terminal UI's native library (downloaded from GitHub releases when it compiles) and the dependency audits. |
| About 600 MB of disk | A first `mix precommit` leaves about 520 MB of dependencies and builds. A test run leaves about 70 MB of test files under the ignored `tmp/` directory, in `tmp/*Test` directories named after the test modules; the next run replaces them rather than adding to them, and you can delete them when no test run is going. It also leaves about 70 KB, and a few empty directories, in the system temporary directory. |

Docker is only needed to run CI's actionlint and ShellCheck steps on your
machine.

## Running the tests

`mix test` runs the ordinary suite. It runs one test case per scheduler, and
it excludes the multi-node tests, which `mix test.distributed` runs. On a
busy machine (a language server, Docker, another build), run it with
`--max-cases 4`.

### What the suite keeps out

The suite does not depend on your machine's settings. Every run sets
`LMX_CONFIG=none` and `LMX_PROJECT_MCP=0` and unsets every other `LMX_*`
variable. Unless you select paid tests, it also removes every provider key
from its environment (each `*_API_KEY`, and each variable ReqLLM reads a key
from), takes back what the checkout's `.env` set, and stops ReqLLM loading
`.env` again. Git runs with the suite's own global configuration and no
system configuration, so `commit.gpgsign`, `core.hooksPath`, a global ignore
file, or running the suite from a pre-commit hook cannot change a result. The
suite does not replace your home directory: `~/.lmx`, `~/.claude` and
`~/.codex` are not isolated.

### Paid tests

Tests tagged `:live` or `:eval_live` call real model providers and spend real
money. You never need them to contribute, and CI does not run them. They are
excluded by default, and selecting them (with `--only` or `--include`) stops
the run before any test starts unless `LEMIEUX_ALLOW_SPEND=1` is set on the
command line for that run:

```sh
LEMIEUX_ALLOW_SPEND=1 mise exec -- mix test --only live test/lemieux/live/providers_test.exs
```

A paid run keeps your provider keys and `LMX_OLLAMA_MODEL`. A live test you
name by its line (`mix test path:LINE`) is reported as skipped, with the
reason, unless `LEMIEUX_ALLOW_SPEND=1` is set for the run; a local Ollama
server is not asked either. To run one live test:

```sh
LEMIEUX_ALLOW_SPEND=1 mise exec -- mix test --include live test/lemieux/live/providers_test.exs:LINE
```

With `LEMIEUX_ALLOW_SPEND=1` but without `--include live`, the run is not a
paid one: your keys are removed, so the hosted providers' tests skip and only
the ones that need no key (the Ollama rows) run. A test you tag `:live` or
`:eval_live` also needs `skip: LemieuxTest.Spend.skip()` at the same level
(`@tag`, `@describetag` or `@moduletag`); `test/suite_isolation_test.exs`
fails without it.

A `LEMIEUX_ALLOW_SPEND` line in `.env` is refused: ReqLLM loads that file
into every run in the checkout, so the line would approve every later paid
run. A coding agent must never set the variable. For Claude Code users, the
repository's `.claude/settings.json` denies the usual spellings of these
commands; that is a second safeguard, not a security boundary.

## Commit addresses

Every commit's author and committer addresses become public once the commit
is pushed. CI's *Commit identities* check therefore requires a GitHub noreply
address on every commit a pull request adds. Find yours under
[Settings → Emails](https://github.com/settings/emails); it looks like
`ID+USERNAME@users.noreply.github.com`. Set it in your clone:

```sh
git config user.email ID+USERNAME@users.noreply.github.com
```

To fix commits you already made, rewrite them on top of the branch you
started from, then force-push:

```sh
git rebase --exec 'git commit --amend --no-edit --reset-author' origin/main
git push --force-with-lease
```

## What CI checks

| Check | What it runs |
| --- | --- |
| Lint & test | unused dependencies, compilation with warnings as errors, the format check, xref, Credo, the usage-rules check, the docs build, `mix test` and `mix test.distributed` |
| Elixir floor (1.19 / OTP 28) | compilation and the suite on the oldest Elixir minor that `mix.exs` accepts |
| Security | `mix hex.audit` and `mix deps.audit` for the library and for `dist/lmx`, and lockfile drift between the two |
| Dialyzer | `mix dialyzer` |
| Hex package (pinned) and Hex package (floor Elixir 1.19.0 / OTP 27.0) | builds the package and compiles it as a dependency (`scripts/check_package.sh`) |
| Example NAME | each example project, and the bundled System One compaction extension, against this checkout (`scripts/check_example.sh NAME`) |
| Standalone release host | compilation, the format check and the tests of `dist/lmx` |
| Docs links | `python3 scripts/check_links.py` |
| Public wording | `scripts/check_public_text.sh` |
| Lint workflows | actionlint, ShellCheck on `scripts/*.sh`, the static Linux build's checksum pins, and a check that no workflow uses a secret or a privileged trigger |
| Tutorial and release helpers | the hello-extension tutorial and the Python release-helper tests |
| Commit identities | a noreply address on every new commit |
| Secret scan (full history) | gitleaks over every reachable commit, pull-request heads included |

Pull requests from forks get a read-only token and no secrets. Scheduled
workflows run the suite on macOS and check test coverage (`nightly.yml`), and
run the recorded offline evaluation (`eval.yml`); neither runs on pull
requests.

`mix precommit.full` runs most of this on your machine: `mix precommit`, the
multi-node suite, the package check, every example and the Python tests. It
needs network access and `python3`, and it is slow; use it when a change
reaches the examples, the package boundary or the release scripts. Some of
its parts, and two quick text checks, also run on their own:

```sh
python3 scripts/check_links.py                        # Docs links
scripts/check_public_text.sh                          # Public wording
python3 -m unittest discover -s test -p 'test_*.py'   # the release helpers
mise exec -- scripts/check_example.sh hello           # one example
```

## When a local check fails

| Symptom | Fix |
| --- | --- |
| `python3 is required to run this suite, and it is not on PATH` | Install Python 3 (macOS: `xcode-select --install`; Debian or Ubuntu: `apt install python3`). |
| `this run selects tests tagged :live or :eval_live` | You selected [paid tests](#paid-tests). Drop the `--only` or `--include` option. |
| `could not remove files and directories recursively ... file already exists` | An interrupted run left read-only files behind. The suite gives its own `tmp/*Test` directories their write permission back when it starts, and a resumed discovery campaign does the same for the attempt a kill interrupted. For any other path, such as a campaign you will not resume, make sure no test run, discovery campaign or extension workbench is using it, then run `chmod -R u+w PATH && rm -rf PATH` with the path the error names. Never delete all of `tmp/`: a running discovery campaign keeps its sealed evidence there. |
| Unrelated `assert_receive` or timeout failures | The machine is busy. Run `mix test --max-cases 4`. If a failure repeats on an idle machine, open an issue. |
| Dialyzer reports `File not found` for an Erlang file | Its cache was built for another Erlang installation. Delete `_build/plts` and run it again. |
| Formatting differs from CI | Use the Elixir version pinned in `.tool-versions`. |
| `mix test.distributed` cannot start nodes | `epmd` must be able to run and listen on your machine. |
| Screens of warnings while dependencies compile | Third-party code meeting the pinned Elixir's type checker. They are harmless: `--warnings-as-errors` applies to Lemieux's own code. |

## Find the right layer

New to the vocabulary (host, session, harness, extension, transcript)? The
[documentation overview](docs/index.md) defines each term.

| Change | Start here |
| --- | --- |
| Session lifecycle and requests | `lib/lemieux.ex`, `lib/lemieux/session.ex`, `lib/lemieux/request.ex` |
| Tools and their execution | `lib/lemieux/tools/`, `lib/lemieux/environment/`, `lib/lemieux/hooks.ex` |
| Checkpoints and undo | `lib/lemieux/checkpoint.ex`, `lib/lemieux/checkpoint/` |
| Extension composition | `lib/lemieux/extension.ex`, `lib/lemieux/harness.ex`, `lib/lemieux/extensions/` |
| Context and compaction | `lib/lemieux/compaction.ex`, `lib/lemieux/compaction/` |
| `lmx` commands and configuration | `lib/lemieux/cli.ex`, `lib/lemieux/cli/`, `lib/mix/tasks/lmx.ex` |
| Terminal UI | `lib/lemieux/tui.ex`, `lib/lemieux/tui/`, `lib/lemieux/conversation/`; read `deps/ex_ratatui/usage-rules.md` first |
| Persistence and compatibility | `lib/lemieux/entry.ex`, `lib/lemieux/store/`, `test/lemieux/resume_test.exs` |
| MCP | `lib/lemieux/mcp.ex`, `lib/lemieux/mcp/` |
| Provider protocols | Upstream in [ReqLLM](https://github.com/agentjido/req_llm). Lemieux owns only the session/provider integration (`lib/lemieux/providers/`); read `deps/req_llm/usage-rules.md` first. |
| The installed binary: release, launcher, updates, notices | `dist/lmx/`, `scripts/install.sh`, `scripts/install.py` |
| The bundled System One compaction extension | `dist/lmx/extensions/systemone_compaction/` |
| Optional learning and evaluation | `lib/lemieux/learning/`, `eval/`, `examples/` |
| CI and release automation | `.github/workflows/`, `scripts/` |

The two `usage-rules.md` files exist after `mix deps.get`.

Design reasoning lives next to the code: in the `@moduledoc` of the module
that owns a decision, the `@doc` of the function that makes it, or a comment
on the expression it is about. `docs/` holds guides that describe current
behaviour and its limits, and the [roadmap](docs/roadmap.md) lists the work
that remains. Runnable examples and their fixtures go under
[`examples/`](https://github.com/houllette/lemieux/tree/main/examples), and
benchmark inputs under
[`eval/`](https://github.com/houllette/lemieux/blob/main/eval/README.md).
Experiment reports, transcripts and review notes do not belong in the
repository.

Many changes do not need to land in Lemieux at all. An extension can ship
your own tools, hooks, prompts and terminal UI settings; the
[customization guide](docs/customization.md) helps you choose, and
[the hello example](https://github.com/houllette/lemieux/blob/main/examples/extensions/hello/README.md)
is a complete one to start from.

## Proposing larger changes

Start a conversation in
[Discussions → Ideas](https://github.com/houllette/lemieux/discussions/categories/ideas)
before you invest in:

- a new dependency, above all anything web- or database-shaped (the core
  deliberately has neither);
- a provider adapter (providers belong in ReqLLM);
- a change to the transcript format, the extension or hook contracts, or
  supervision;
- a behaviour that `lmx` turns on by default;
- a new platform or install method.

These surfaces are kept small on purpose, and a short conversation can save
you a rewrite. Bug fixes, tests and documentation fixes need no discussion
first.

A dependency change can also reach the `lmx` binary's third-party notices.
The release build stops on a bundled package whose license it cannot
identify, and on an `ex_ratatui` version whose list of Rust crates was not
regenerated; the `dist/lmx` tests check the crate list too.
[Third-party notices](https://github.com/houllette/lemieux/blob/main/dist/lmx/README.md#third-party-notices)
says what to update.

## Public contracts and documentation

Read [Support](docs/support.md) before you change callbacks, transcript
schemas, flags or extension bundle compatibility, and add a migration note to
`CHANGELOG.md` when you do. Exercise public library changes in
`test/package_consumer`, which compiles the packaged source without the
terminal UI (`scripts/check_package.sh`). The first-session example and the
hello-extension tutorial run offline in CI: keep their commands working, and
never make a deterministic example test need a model key.

`scripts/check_example.sh NAME` checks one example project against your
checkout, the way CI does; it looks for `NAME` under `examples/extensions/`,
then under `dist/lmx/extensions/`. The planning example has no Mix project,
so the root suite checks it.

## AI-assisted contributions

Lemieux is developed with coding agents, and AI-assisted pull requests are
welcome.
[AGENTS.md](https://github.com/houllette/lemieux/blob/main/AGENTS.md) (which
`CLAUDE.md` includes) tells an agent how to work here, including never to
start a paid model call you did not ask for. You are still the author:
understand every line you submit, run the tests and the gate yourself, and
say in the pull request if most of the change was generated.

## Releases and signing keys

The maintainer cuts releases, following
[RELEASING.md](https://github.com/houllette/lemieux/blob/main/RELEASING.md).
A pull request must not change `dist/lmx/release-signing.pub` or the
`RELEASE_PUBLIC_KEY` line in `scripts/install.py`: they change only when the
maintainer runs `mix lmx.release.keygen`. A test that needs a signing key
generates a throwaway one outside the checkout; the signing tasks refuse a
key inside a Git working tree.

## Reports and privacy

Use the [issue forms](https://github.com/houllette/lemieux/issues/new/choose).
A bug report needs the version (`lmx --version`, plus
`git rev-parse --short HEAD` for a source checkout), your OS and terminal, the
provider and model (never the key), a small reproduction, and redacted
`lmx explain` output. A feature proposal describes the task first, and why an
existing hook, tool or extension does not cover it.

Never post API keys, OAuth tokens, `.env` files, session transcripts or
proprietary fixtures: transcripts and logs can contain source code and
secrets. Keep keys in your shell or in files Git ignores (`.env`, `.envrc`,
`mise.local.toml`, `*.pem` and `*.key` are ignored). A test fixture that
holds a deliberately fake key needs `git add -f`.

## License

Lemieux is licensed under [Apache-2.0](LICENSE), and contributions are
accepted under the same license: inbound = outbound, as section 5 of the
license provides. There is no contributor license agreement and no sign-off
requirement. Keep existing copyright and license notices, and say where any
third-party material you copy comes from and under which license.

## Maintainer

Lemieux has one maintainer, [@houllette](https://github.com/houllette), who
reviews pull requests and decides scope, design and releases. Reviews are
best-effort. Before 1.0, a good change that widens the core may be declined:
extensions exist so that you can ship an opinion without changing Lemieux
itself.
