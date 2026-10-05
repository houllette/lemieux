# Examples

Runnable programs that show Lemieux from the smallest embedded session up to
whole-task agents. Every example below has an offline check (tests, a scripted
benchmark or a compile) that needs **no API key and makes no model calls**; the
"Live use needs" column says what a real run needs on top of that. Examples
need Elixir 1.19 or newer; `mise install` in the repository sets up the pinned
toolchain.

New here? Run the first one from the repository root, then read
[Your first extension](../docs/first-extension.md) with `extensions/hello` open.

```sh
mise exec -- mix run examples/first_session.exs
# Hello from Lemieux   (the first run compiles dependencies first; upstream
#                       packages print some warnings, which are harmless)
```

Where an example runs `lmx` and you have no installed binary, use
`mise exec -- mix lmx` from the repository root instead: it runs the same
commands from this checkout.

## Start here

| Example | What it shows | Offline check | Live use needs |
| --- | --- | --- | --- |
| [`first_session.exs`](first_session.exs) | A complete embedded session with a scripted model | `mix run examples/first_session.exs` | Nothing; see [First embedded agent](../docs/first-embedded-agent.md) for a real provider |
| [`extensions/hello`](extensions/hello/README.md) | One deterministic tool packaged as an extension, built into a bundle `lmx` loads | `mix test`; `lmx explain --extension hello` | A provider key to chat with it |
| [`extensions/planning`](extensions/planning/README.md) | The smallest **script** extension: one `.exs` and an `extension.json`, no Mix project, adding a deterministic `plan_order` tool | The root suite; `lmx explain --extension-dir examples/extensions/planning` | A provider key to chat with it |

## Agents built on the library

Each is an ordinary Mix project with its own `mix.exs`. Outside this checkout
it depends on `lemieux` from Hex (`~> 0.8`). Inside the checkout, point it at
your working copy first: `export LEMIEUX_EXTENSION_BASE="$PWD"` from the
repository root. Where an example's own scripts call a model, you name it as
`provider:model` in `LMX_MODEL` (`RESEARCH_MODEL` for the research benches).

One thing to know about that switch:

- `mix deps.get` with `LEMIEUX_EXTENSION_BASE` set resolves the lock against
  your checkout: it changes the tracked `mix.lock` in `extensions/hello` and
  `extensions/research`, and writes an untracked one in the others.
  Neither belongs in a commit. Restore a tracked lock with
  `git checkout -- mix.lock` and delete a new one; `scripts/check_example.sh`
  (below) does this for you.

| Example | What it shows | Offline check | Live use needs |
| --- | --- | --- | --- |
| [`extensions/review`](extensions/review/README.md) | A review agent that validates the paths and lines it reports | `mix test`; `mix lemieux.extension.eval bench/compare.exs` (scripted) | A host's provider, model and key |
| [`extensions/verifier`](extensions/verifier/README.md) | Run the project's own tests after a change, retry once on failure | `mix test` | `LMX_MODEL` and its provider's key |
| [`extensions/research`](extensions/research/README.md) | Search, fetch and quote-checked citations | `mix test`; `mix lemieux.extension.eval bench/compare.exs` (local fixture pages) | A model and its key, and `BRAVE_SEARCH_API_KEY`; the live benches default to an Ixway route, `RESEARCH_MODEL` picks another |
| [`extensions/security`](extensions/security/README.md) | Wrapping an external tool (Nmap) in bounded tools, with a hook that keeps scans to configured targets | `mix test` | `LMX_MODEL` and its key; Nmap only if you actually scan |
| [`extensions/capture`](extensions/capture/README.md) | A `session_end` hook that turns failed sessions into draft eval cases | `mix test` | Nothing of its own: it drafts from the sessions you already run |
| [`extensions/builder`](extensions/builder/README.md) | The guided extension builder exercised as an ordinary extension | `mix compile` | `LMX_MODEL` and its key, with dollar caps or quota request bounds |

## Experimental integrations

| Example | What it shows | Offline check | Live use needs |
| --- | --- | --- | --- |
| [`extensions/computer_use`](extensions/computer_use/README.md) | Experimental headless **browser** use (not desktop control) | `mix check` | Chrome and ChromeDriver, `JEV_API_KEY` (TypeSafe, billed), and a text model key |

Jev compaction, which used to live here, is part of the `lmx` release:
[`dist/lmx/extensions/jev_compaction`](../dist/lmx/extensions/jev_compaction/README.md).

## Research drivers (maintainers)

`experiments/` and `discovery/` are the scripts behind the measurements in
[Evaluation gates](../docs/evaluations.md) and
[Harness learning](../docs/harness-learning.md). They make **live, billed or
quota-consuming** model calls and are not needed to use or extend Lemieux.
Read a script's header before running it: it names the models it calls and
the bounds it keeps. An experiment that calls a model runs only on one you
name (`LMX_MODELS`, `LMX_SOAK_MODEL`, `LMX_INVESTIGATORS_MODEL`,
`LMX_DELEGATE_BUDGET_MODEL`); none picks a provider for you. The discovery
configurations run through `mix lemieux.discovery` and
`mix lemieux.discovery.cycle`, which make no provider call without
`--allow-live`. `experiments/transcript_labels.exs` reads your own
`~/.lmx/sessions` and sends anonymized digests of them to two model providers;
it refuses to send anything without `--allow-live`, and
`LMX_LABELS_DIGEST_ONLY=1` writes the digests locally for you to inspect.

The synthetic tasks these drivers and the evaluation gate run on are in
[`eval/`](../eval/README.md).

Check an example's Mix project against this checkout the way CI does, from
the repository root: `scripts/check_example.sh NAME`, for `hello`, `review`,
`verifier`, `research`, `security`, `capture`, `builder` or `computer_use`.
`extensions/planning` has no Mix project; the root suite checks it
(`test/lemieux/planning_example_test.exs`).

## License

Example code is part of Lemieux and licensed under Apache-2.0 (see the root
[LICENSE](../LICENSE)). You may copy it into your own extension; keep the
license notice if you redistribute substantial portions. `extensions/computer_use`
also adapts MIT-licensed code; its [NOTICE](extensions/computer_use/NOTICE)
carries that license.
