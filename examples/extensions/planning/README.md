# Script extension example

- **What it shows:** the smallest kind of extension, one Elixir script and a
  manifest, adding a deterministic tool (`plan_order`) to `lmx`.
- **Runs offline?** Yes. Loading it and `lmx explain` make no model call, and
  the root test suite checks it (`test/lemieux/planning_example_test.exs`).
- **Needs:** `lmx` or this source checkout. A chat with it uses whichever
  model you normally run.

`planning.exs` defines the extension and its tool. `extension.json` names the
module, the script and the Lemieux it was written for:

```json
{"schema_version": 1, "name": "planning", "module": "LemieuxPlanningExample",
 "script": "planning.exs", "versions": {"lemieux": "~> 0.8"}}
```

`lmx` compiles the script when it loads the directory, so there is no Mix
project and nothing to rebuild after a Lemieux patch upgrade.

## The tool

`lmx` already keeps a session plan with its `todo` tool. `plan_order` helps
with the part that is easy to get wrong: putting dependent steps in an order
that works. Given steps and what each one comes after, it returns an order in
which every step follows its dependencies:

```json
{"steps": [
  {"id": "deploy", "after": ["migrate", "test"]},
  {"id": "test", "after": ["write code"]},
  {"id": "migrate", "after": ["review schema"]},
  {"id": "write code"},
  {"id": "review schema"}
]}
```

```text
1. write code
2. test
3. review schema
4. migrate
5. deploy
```

It is pure Elixir: no files, no network and no model. Steps that are free to
go next keep the order they were given in, so the same input always gives the
same answer. A dependency cycle or a dependency on a step that does not exist
comes back as an error the model reads, rather than as a guess. The tool says
it is read-only and safe to run beside other calls (`read_only?/0` and
`parallel_safe?/0`), because both are true.

## Load it

Loading is explicit: `lmx` never picks up an extension because a repository
contains one. From the repository root:

```sh
lmx explain --extension-dir examples/extensions/planning   # no model call
lmx --extension-dir examples/extensions/planning           # the TUI, with plan_order
```

From a source checkout without an installed `lmx`, use `mise exec -- mix lmx`
in place of `lmx`. `explain` lists `LemieuxPlanningExample` under
`extensions` and `plan_order` under `tools`. Ask for a plan whose steps depend
on each other and the model can call `plan_order` before it records the plan
with `todo`.

To load it by name, copy the directory to `~/.lmx/extensions/planning` and use
`lmx --extension planning`, or add `"extensions": ["planning"]` to your
`~/.lmx/config.json`.

## Write your own

`lmx extension new NAME` writes the same layout under `~/.lmx/extensions/NAME`.
Keep `apply/2` to adding what `lmx` does not already have: two tools with the
same name stop a session before its first request. An earlier version of this
example added a second `todo` tool and broke every session it was loaded into.
See [A script extension instead](../../../docs/first-extension.md#a-script-extension-instead)
for the manifest rules. For a capability that already exists as a service, an
MCP server needs no Elixir at all.
