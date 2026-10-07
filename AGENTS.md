# Agent Guidelines

## Project overview

**An open-source coding agent you can take apart: a terminal app (lmx), and the Elixir runtime underneath it (Lemieux).**

Lemieux runs the agent loop itself — model calls through provider APIs,
built-in tools (read, write, edit, bash and more), and an event-sourced
transcript that supports resume, fork and replay — instead of wrapping a
vendor CLI. `lmx` is the terminal app most people meet first. The library
underneath is what other Elixir applications embed. A host — `lmx`, or any
application that embeds Lemieux — supplies credentials and storage, and
attaches its own policy through hooks (tool approval, sandboxing, budgets).

Five decisions shape everything else. Each is documented next to the code it
constrains — the modules named below are where the reasoning lives:

- **The loop is ours, not a subprocess's.** Running it is what makes resume,
  fork and replay possible at all: they are reads over the transcript, and no
  amount of scraping a vendor CLI's terminal output reconstructs one after the
  fact. See `Lemieux`.
- **Providers go through `req_llm`.** There are no hand-rolled provider
  adapters in this repo, and adding one is the wrong instinct — a new provider
  is that library's problem. See `Lemieux`.
- **The core takes no web and no database dependency.** Anything that would
  force a repo or an endpoint into this tree belongs in a host instead. CI has
  no Postgres service for exactly this reason.
- **Adding the dependency starts no Lemieux processes.** There is deliberately
  no `mod:` entry in `mix.exs`; hosts mount `Lemieux.Supervisor` into their
  own tree and own its lifecycle. Lemieux's dependencies are ordinary OTP
  applications and still start (`req_llm` starts its HTTP pool). A test
  asserts the absence of `mod:`, so restoring it fails the suite rather than
  silently changing the contract every embedder codes against. See
  `Lemieux.Supervisor`.
- **Opinions are extensions; the core names none of them.** A default a
  host might disagree with lives behind a behaviour whose shipped default is
  in the same module (`Lemieux.Compaction`, `Lemieux.Messages`,
  `Lemieux.Session.Guard`, `Lemieux.TUI.Status`), or in a shipped extension
  under `Lemieux.Extensions`. `Lemieux.Harness` holds every seam's setting,
  and an extension's `apply/2` callback (`Lemieux.Extension`) is how code
  changes one. `test/lemieux/boundary_test.exs` reads the compiled beams and
  fails when a core module reaches a host or the learning toolchain, or when
  anything below a host reaches one; its debt list is empty and must stay so.
  See `Lemieux.Extension` and `Lemieux.Harness`.

`lmx` itself is a host like any other (`Lemieux.CLI`) — it gets no privileged
path into the library, which is what keeps embedded-only bugs from hiding.
The installed binary is built by a separate Mix project, `dist/lmx`, which
owns the application callback, the launcher and updates.

**Runs as a single node.** No DNSCluster, no libcluster, no Horde: a CLI
process and an embedded library each own their own runtime. If cluster-wide
session identity is ever needed, that is the host's problem to solve.

### Where the reasoning lives

Design decisions go in the `@moduledoc` of the module that owns them, the
`@doc` of the function that makes them, or an inline comment on the expression
they are about — **not in this file.** A rule that lives next to its code is
the one that gets read before the code changes, and the one that gets
corrected when it stops being true. Say what would go wrong under the obvious
alternative, and name the failure if it has already happened.

People contributing by hand start with `CONTRIBUTING.md`; this file holds the
same conventions, written so that coding agents follow them too.

## Commands

**Run `mix precommit` when you think you're done.** One alias runs what CI's
Lint & test, Security, Dialyzer and Standalone release host jobs check, except
the multi-node suite: the dependency audits (for the library and the
`dist/lmx` release host), warnings-as-errors compilation, Credo, xref, the
docs build, the ordinary suite, Dialyzer and the release host's own gate. It
formats rather than checks formatting, and it regenerates the usage-rules
block below, so commit what it rewrote. It stops at the first failing step,
and its exit status is the result. It needs network access for the audits
and `python3` for the suite.

CI runs more than that: the multi-node suite, the suite on the oldest
supported Elixir minor, the Hex package compiled as a dependency (also on the
oldest supported toolchain), every example project and the bundled System
One compaction extension, the Python release-helper tests, and the link, wording, workflow,
commit-identity and secret-scan checks. **Run `mix precommit.full` before a
release or when a change reaches the examples, the package boundary or the
release scripts.** It adds the multi-node suite, the package check, every
example and the Python tests, and needs network access and `python3`.
`mix ci` is the `precommit` gate in check mode, rewriting nothing; the release
pipeline runs it.

The suite needs `python3` (its MCP and process fixtures are Python), `git`
2.28 or newer, `make` and a `kill` executable, and it must not run as root;
`mix test.distributed` also needs `epmd`. It runs one test case per scheduler
and takes under a minute on a fast machine; under heavy outside load (a
language server, Docker, another build), pass `--max-cases 4`.

| Task | Command |
| --- | --- |
| Everything (run this before you're done) | `mix precommit` |
| Everything CI runs, including examples and package checks | `mix precommit.full` |
| The precommit gate without rewriting files | `mix ci` |
| Run any `lmx` command from this checkout (bare, it opens the terminal UI) | `mix lmx ARGS` |
| Check one example project, or the bundled compaction extension | `scripts/check_example.sh NAME` |
| Check the release host's lock matches the library's | `mix deps.drift` |
| Install deps | `mix deps.get` |
| Compile (warnings are errors in CI) | `mix compile --warnings-as-errors` |
| Run all tests | `mix test` |
| Run one test file | `mix test test/path/to/file_test.exs` |
| Run one test | `mix test test/path/to/file_test.exs:LINE` |
| Run the suite on a heavily loaded machine | `mix test --max-cases 4` |
| Run the ordinary suite with warnings as errors | `mix test.fast` |
| Run the multi-node suite (needs `epmd`; the alias starts it) | `mix test.distributed` |
| Run both suites | `mix test.full` |
| Run the Python release-helper tests | `python3 -m unittest discover -s test -p 'test_*.py'` |
| Format | `mix format` |
| Lint | `mix credo --strict` |
| Compile-time dependency check | `mix xref graph --label compile-connected --fail-above 0` |
| Type check (first run builds a PLT cache, slow once) | `mix dialyzer` |
| Dependency vulnerabilities | `mix deps.audit` |
| Retired packages | `mix hex.audit` |
| Check Markdown links the way GitHub renders them | `python3 scripts/check_links.py` |
| Check for private names and launch-state wording | `scripts/check_public_text.sh` |
| Check the static Linux build pins this toolchain | `scripts/build-static-otp.sh --check-pins` |
| Lint shell scripts with CI's ShellCheck (needs Docker) | `docker run --rm --entrypoint shellcheck -v "$PWD:/repo:ro" -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 scripts/*.sh` |
| Build the native `lmx` binary | `cd dist/lmx && LMX_TARGET=TARGET MIX_ENV=prod mix release --overwrite` |
| Test the release host | `cd dist/lmx && mix test --warnings-as-errors` |
| Refresh AGENTS.md usage rules | `mix usage_rules.sync --yes` |
| Check those rules are current | `mix usage_rules.sync --check` |
| Search dependency docs | `mix usage_rules.search_docs "term" -p package` |

The `precommit` alias in `mix.exs` is the authoritative list for this project.

Two orderings in that alias are load-bearing and documented where they live:
the audits must precede `compile` (which drops the Hex archive from the code
path), and `usage_rules.sync` must never run bare (it prompts, and hangs a
non-interactive shell).

`mix lmx ARGS` takes exactly the installed binary's arguments, so every `lmx`
command in the guides runs from a source checkout, and its hints say
`mix lmx`; `mix lmx.tui` still opens the terminal UI. Run from the repository
root, it reads the checkout's `.env`. Run from `dist/lmx` (after a
`mix deps.get` there, since it is a project of its own), `mix lmx` keeps the
repository root as its workspace, includes the bundled System One compaction
extension (which acts only when a System One provider is configured) and, like
the binary, reads no `.env`. Mix prints compile progress on standard output,
so run `mix compile` once before redirecting `mix lmx run …`.

### Releases

The shipped `lmx` is the OTP release host in `dist/lmx`, not the `:lemieux`
application. Keep that separation: the release owns an application `mod:`,
while library embedders rely on `:lemieux` starting no processes of its own.
`dist/lmx/README.md` covers building one target with `LMX_TARGET` on a
matching host, and testing it. The Linux archive is a glibc build: never
export `TARGET_ABI=musl`, which would bundle the terminal library's musl NIF.

For every version bump, prepare `dist/lmx/upgrades/VERSION.exs` as
`dist/lmx/upgrades/AGENTS.md` describes. Upgrade paths require an exact prior
build and explicit compatible-module instructions; a missing path means
restart. Release CI requires a reviewed per-platform hot/restart decision and
qualification of the actual archives; a generated module diff alone does not
establish state compatibility. Every declared hot target must package
`releases/VERSION/relup` and both application appups with qualified
upgrade/downgrade paths. Only initial and explicitly reviewed restart
decisions may omit relup. The maintainer cuts releases: `RELEASING.md` holds
the procedure, and `docs/releases.md` what users install and how updates
reach them.

Release signing keys:

- `dist/lmx/release-signing.pub` and the `RELEASE_PUBLIC_KEY` line in
  `scripts/install.py` change only through `mix lmx.release.keygen`, which
  the maintainer runs. Never run `mix lmx.release.keygen`,
  `mix lmx.release.sign` or `mix lmx.release.sign_draft`, and never generate,
  hold or print a real release key. `mix lmx.release.verify` needs no private
  key.
- Tests use throwaway keys: `:crypto.generate_key(:eddsa, :ed25519)` or the
  RFC 8032 vectors. The signing tasks refuse a private-key path inside any Git
  working tree, and ExUnit's `tmp_dir` is inside this one, so signing tests
  create their keys under `System.tmp_dir!/0`.
- To regenerate `test/fixtures/install`, follow the recipe in the docstring
  of `test/test_install_signing.py`. Never use keygen for it.

## Conventions

- **Run `mix precommit` before declaring work finished.** Fix what it reports
  rather than narrowing the check or adding a suppression. If a check is
  genuinely wrong for this project, change the config in a separate commit and
  say why.
- **Format before committing.** CI enforces `mix format --check-formatted`,
  which also covers `.credo.exs`, `examples/*.exs`,
  `examples/{discovery,experiments}/*.exs` and `scripts/*.exs`.
- **No compiler warnings.** CI compiles with `--warnings-as-errors`, and tests
  run with `--warnings-as-errors` too — test files are held to the same bar.
- **Test-first when practical.** Add or update an ExUnit test that captures the
  behavior change, watch it fail, then implement. Use `async: true` in test
  modules unless they share global state (named processes, Application env).
- **A test must be able to fail.** No test without an assertion, and no
  assertion that holds regardless of the code under test (`assert x == x`,
  or `assert is_map(result)` where every return value passes). If you can't
  write an assertion that would have failed before the change, the test isn't
  earning its keep.
- **Never spend money unasked.** Start nothing that calls a hosted model
  unless the person you are working for asks for that run. That includes:
  - tests tagged `:live` or `:eval_live`. They are excluded by default, a
    run that selects them stops before any test starts unless
    `LEMIEUX_ALLOW_SPEND=1` is set on the command line for that run (a line
    in `.env` is refused), and one named by its line (`mix test path:LINE`)
    is reported as skipped without it. Never select those tags, and never
    set `LEMIEUX_ALLOW_SPEND`;
  - any `--approve-live` or `--allow-live` flag (`mix lemieux.eval`, the
    `mix lemieux.discovery` tasks, `mix lemieux.extension.eval`,
    `mix lemieux.extension.confirm`, `mix lemieux.extension.compare` and the
    `computer_use` example's bench), and a `mix lemieux.extension.workbench`
    configuration that selects a hosted model;
  - the scripts under `examples/experiments` and `examples/discovery`;
  - `mix lmx run`, or the terminal UI, against a hosted provider.

  The ordinary suite, `mix lmx explain`, `mix lmx --version` and
  `Lemieux.Providers.Scripted` send no model request. `.claude/settings.json`
  denies the usual spellings of the paid-test selections, `--approve-live`,
  `--allow-live`, the workbench's `run-live` and a few paid scripts, as
  defence in depth rather than a boundary; it does not cover every
  configuration that selects a hosted model, the other example scripts or
  `mix lmx run`.
- **Wait with the suite's default.** A test that waits for an event omits the
  `assert_receive` timeout and takes the suite's 5 s default. Shorter explicit
  waits are the ones that fail first under load. `refute_receive` keeps a
  short explicit window (20-200 ms), and only where the test asserts that
  something does not happen. A fixture that must not finish on its own
  during a wait (a retry backoff, a delayed answer, a held attempt) takes a
  minute, far beyond 5 s, so the test cannot pass on the fixture's timer. A
  legitimately long test says so with `@tag timeout: :timer.minutes(3)`
  rather than leaning on the suite's 60 s.
- **Keep a passing run quiet and self-contained.** A passing run prints only
  dots: a test that runs `lmx run`, or anything else that writes to standard
  error, captures it (`capture_io(:stderr, ...)` or `with_io(:stderr, ...)`),
  and a test waits for the turn, observer or task it started to end before
  it returns. A test that runs an agent session or a workbench agent passes
  `sessions_dir:` under its `tmp_dir`; `Lemieux.Agent.Session`'s default is
  the system temporary directory, where transcripts pile up.
- **Tag paid tests twice.** A test tagged `:live` or `:eval_live` also
  carries `skip: LemieuxTest.Spend.skip()` at the same level (`@tag`,
  `@describetag` or `@moduletag`); `test/suite_isolation_test.exs` fails
  without it.
- **Quote paths in shell commands.** When a test builds a shell command around
  a path, quote it with `LemieuxTest.Shell.quoted/1`: a checkout's path can
  contain spaces.
- **Keep the `Test` suffix.** New ExUnit case modules end in `Test`. The test
  helper restores write permission only under `tmp/*Test`, the directories
  ExUnit names after test modules.
- **Never let a test path reach `System.halt/1`.** It takes the whole VM down,
  so the suite dies instead of failing. `Lemieux.CLI` splits `run/1` (returns
  a status) from `main/1` (halts on it) for this reason; keep new commands on
  the same split.
- **Don't add dependencies to solve small problems.** The standard library
  covers date and time (`Date`, `Time`, `DateTime`, `Calendar`), and every new
  dep is one more thing CI has to audit. Ask before adding one — especially
  anything web- or database-shaped, which the core is meant not to have.
- **Pattern match at function heads** rather than with nested `case`/`cond`
  where it reads naturally; use `with` for chains of fallible calls. Never
  write a `case` whose only clauses are `true` and `false` — that's an `if`.
- **Let it crash where appropriate.** Don't defensively rescue exceptions in
  supervised processes; reserve `try/rescue` for genuine boundary concerns.
  Never `rescue` an exception only to log it and continue.
- **Typespecs on public functions.** Dialyzer runs in CI. Name the arguments in
  the spec — `@spec fetch(user_id :: integer()) :: {:ok, t()} | {:error, term()}`.
- **Keep runtime deps out of compile time.** `mix xref graph --label
  compile-connected --fail-above 0` fails the build when a module edit starts
  triggering wide recompiles.
- **Don't edit generated or vendored files** (`deps/`, `_build/`).
- **No outward-facing actions unasked.** Do not push, open, comment on or
  close issues and pull requests, or publish packages, unless the person you
  are working for asks.
- **CI is GitHub Actions only** (`.github/workflows/`). Jobs that need Erlang
  and Elixir install them through `.github/actions/setup`, which also restores
  the Mix caches; its `python: "true"` input adds the pinned Python 3.13 for
  jobs that run the suite or the release helpers. `release.yml` calls
  `erlef/setup-beam` directly and restores no Mix cache, so a release artifact
  never starts from a cache another branch could have written, and its Linux
  job builds its own static Erlang/OTP in a container; `eval.yml` also calls
  `erlef/setup-beam` directly. Jobs that need no BEAM set up only what they
  use (Python for Docs links, Docker for Lint workflows, a pinned gitleaks for
  the secret scan). Every job has a `timeout-minutes`. CI and Public readiness
  run on every push to main and every pull request, with no path filters; job
  names are the status checks a ruleset requires, so rename a required check
  in the same change. GitHub's own `actions/*` follow their major tags;
  third-party actions, the actionlint image and the Linux build container are
  pinned to a commit or digest. No workflow may use a secret or a privileged
  trigger (`pull_request_target`, `workflow_run`, `issue_comment`,
  `discussion_comment`): the Lint workflows job fails if one does, and runs
  actionlint and ShellCheck. Public readiness requires a GitHub noreply
  address on every new commit's author and committer. `nightly.yml` runs the
  suite on macOS and checks the coverage threshold; `eval.yml` runs the
  recorded evaluation on a schedule.

## Framework and library guidelines

This is a plain OTP library with a CLI front end — no Phoenix, no Ecto.

Anything between the `<!-- usage-rules-start -->` and `<!-- usage-rules-end -->`
markers at the end of this file is **generated from the installed
dependencies** by `mix usage_rules.sync`. Never hand-edit inside those markers:
the next sync overwrites it, and CI fails when the block is out of date. Put
your own guidance above the markers instead. After changing dependencies, run
`mix usage_rules.sync --yes` and commit the result.

That task prompts for confirmation, so it hangs if you run it bare in a
non-interactive shell. Always pass `--yes` (write the changes) or `--check`
(exit non-zero if stale, without writing).

The large rule sets are linked rather than inlined, so this file stays small
in every session: **read `deps/ex_ratatui/usage-rules.md` before changing the
terminal UI, and `deps/req_llm/usage-rules.md` before changing provider
code** (both exist after `mix deps.get`). `mix.exs` lists which packages are
linked and which are inlined.

## Versions

Erlang and Elixir are pinned in `.tool-versions`, which mise or asdf read
locally and `erlef/setup-beam` reads in CI. Bump them there. A bump also needs
the new source checksums in `scripts/build-static-otp.sh` (its `--check-pins`
mode fails without them) and, for Erlang/OTP, a review of the components
`Lmx.Notices` records in `dist/lmx/lib/lmx/notices.ex`: the release build
refuses an Erlang/OTP version they were not reviewed for. The floor jobs in
`ci.yml` pin older versions on purpose, to match the `elixir:` requirement
in `mix.exs`; leave them alone when you bump `.tool-versions`.

<!-- usage-rules-start -->
<!-- ex_ratatui-start -->
## ex_ratatui usage
_Elixir bindings for the Rust ratatui terminal UI library_

[ex_ratatui usage rules](deps/ex_ratatui/usage-rules.md)
<!-- ex_ratatui-end -->
<!-- req_llm-start -->
## req_llm usage
_req_llm_

[req_llm usage rules](deps/req_llm/usage-rules.md)
<!-- req_llm-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
