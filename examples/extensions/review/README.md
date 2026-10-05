# Review extension example

- **What it shows:** a code-review agent built on the library: it picks the
  files, runs one bounded session, and checks that every finding names a real
  path and line.
- **Runs offline?** Yes. `mix lemieux.extension.eval bench/compare.exs` uses a
  scripted model, so it needs no key and spends nothing.
- **Needs:** for live use, an embedding host that supplies a provider, a model
  and that provider's key.

This is a native **extension**: an ordinary Mix library that starts nothing
on its own. (Skills and commands from other agents' ecosystems are
**plugins**, a different thing.) The example selects up to eight top-level
Elixir files, runs one bounded Lemieux session, then validates finding paths
and line numbers. No pipeline DSL or second model loop is involved.

From this directory, with an absolute path to your Lemieux checkout:

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix deps.get
mix lemieux.extension.eval bench/compare.exs
mix lemieux.extension.workbench bench/compare.exs
mix lemieux.extension.export . /tmp/review-extension-export
```

The comparison is offline. It feeds one known-good answer and one deliberately
missed finding through the same public agent, twice each. Expect `finds-defect:
2/2` and `missing-finding: 0/2`. The external grader, excluded from agent inputs
and copied workspaces, detects the miss. These scripted responses demonstrate
integration and do not measure a model's review quality. Runtime options and raw
results are not included by the export manifest; the benchmark script contains
only synthetic examples and no credentials.

In the workbench, enter `cases`, `variants`, then `run`. Enter `inspect`, leave
the run ID blank to select the latest run, and choose attempt `1`: the
`missing-finding` extension completed normally but returned `{"findings":[]}`,
so its grader exited with status 1. The summary reports the finding variant's
paired wins and keeps unreported token/cost counters unknown. Run it again to
verify repeatability; each attempt creates a fresh scripted provider.

Use `case` to add or edit a development task, `variant` to create requested
settings from a configured base, and `select` to include them in the next run.
`reports` and `inspect` work after restarting the command. These edits and reports
live in `tmp/extension-workbench`, outside the fixture workspaces and outside
the export manifest. This example fixes its system instructions and tool policy,
so those cannot be changed by a variant's requested system override.

In another Mix application, add:

```elixir
{:review_extension, path: "/tmp/review-extension-export"}
```

Outside this checkout the example depends on `lemieux` from Hex. For
development against this checkout, set `LEMIEUX_EXTENSION_BASE` to its
absolute path; unset it to use the Hex release. Export preserves `mix.exs` and
does not publish to Hex or install the extension into `lmx`.

Run it through the public entry point, supplying the host's provider, model
and options:

```elixir
Lemieux.Agent.run(ReviewExtension,
  %{prompt: "Review the public error contract", cwd: "/path/to/source", timeout_ms: 60_000},
  provider: provider,
  model: model,
  supervisor: MyHost.Lemieux,
  session_options: [max_turns: 4, max_cost_usd: 1.00]
)
```

The host owns credentials, isolation and limits. Files are passed as data and
this example grants no model tools. Location validation does not certify that a
finding is true. An exported extension is marked `unassessed`: nothing has
measured how well it reviews code, and a green development comparison is
neither an independent confirmation nor a reason to switch it on
automatically.

To try frozen evaluation from this example Mix project:

```sh
mix lemieux.extension.freeze bench/freeze.exs /tmp/review-frozen
```

Keep the printed SHA-256, then use `Lemieux.Learning.Extension.Build.open/2` with that
expected digest and `Build.run/2` with the same prompt/workspace/timeout input.
The consumer compiles this frozen source in a fresh BEAM and resolves the exact
scripted profile through `ReviewExtension.configure/1`. Default dependency
runtime assets are included; no provider credentials are needed.

This example's case has been seen during development, so it cannot serve as
hidden evidence in a confirmation. The
[confirmation guide](../../../docs/agent-extensions.md#confirmation-and-qualified-export)
describes held-out case sets, clustered comparisons, source export and receipt
verification. The scripted profile demonstrates the integration; this example
makes no claim about live review quality.
