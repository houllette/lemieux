---
name: create-extension
description: Create or change a Lemieux extension, native tool, agent, or profile using the normal TUI and project tests.
argument-hint: "what the extension should do"
---

# Create a Lemieux extension

Use the ordinary TUI's read, write, edit and bash tools. This skill supplies
guidance; it does not select a model, change the session budget, or install code.
Honor the user's existing brief. Ask only for a missing decision that prevents
implementation, such as the intended host or an external system's contract.

## Pick the seam

Start with the lightest one that does the job:

- Reusable instructions alone: an Agent Skill (`SKILL.md`). No Elixir module is
  needed.
- A capability that already exists as a service or another language's code:
  an MCP server, configured in `.mcp.json` or `~/.lmx/config.json`. No Elixir
  and no rebuild when Lemieux upgrades.
- A policy check on tool calls or prompts: a command hook (`--hooks FILE`, or
  `"hooks"` in `~/.lmx/config.json`). A Claude Code hooks file loads with
  `--hooks`, but with documented differences: `tool_input.file_path` is the
  path the model wrote, often relative to `cwd`; `tool_response` is
  `{output, error}`; `if` is ignored and comma-separated matchers do not
  match. Check docs/hooks.md "What is not supported yet" before relying on
  one as a guard.
- A small Elixir change for the installed `lmx`: a **script extension** — one
  `.exs` file and an `extension.json` whose `versions` names only Lemieux
  (`{"lemieux": "~> 0.8"}`). It compiles in the running `lmx`, so there is
  nothing to rebuild after an Elixir or Lemieux patch upgrade. `lmx extension
  new NAME` writes a working one to start from.
- A model-callable capability: a module implementing `Lemieux.Tool`.
- Composition of prompt, tools, hooks or policy: `Lemieux.Extension`.
- Portable session settings: `Lemieux.Extension.Profile` JSON.
- A whole multi-step task: `Lemieux.Agent`, optionally backed by an extension.

If asked for an extension, build the requested behavior; do not route every
request through the benchmark workbench. Keep credentials, routing, budgets,
supervision and execution policy with the host. The library core starts nothing
and does not take a web or database dependency.

## Build

1. Inspect the target project, its `AGENTS.md`, `mix.exs`, existing extension
   modules, and the relevant Lemieux API. In a Lemieux source checkout,
   `docs/first-extension.md`, `docs/extensions.md`,
   `examples/extensions/hello` (a Mix project) and
   `examples/extensions/planning` (a script extension) are useful working
   references. An installed
   binary may not have those source files; the contract below is sufficient
   to start a small extension.
2. Write one concrete behavior check that fails before the change when
   practical. For a tool, test its deterministic `run/2` directly; for the
   model loop, use `Lemieux.Providers.Scripted` without spending provider quota.
3. Implement the smallest module set. `Lemieux.Extension` requires
   `apply(harness, state)` and optionally `init(opts)` and `describe(state)`.
   Put `import Kernel, except: [apply: 2]` in the extension module. Use
   `Lemieux.Harness.update_system/2`, `update_tools/2`, `append_host_tools/2`,
   or `append_hooks/2` to compose with existing harness fields. `apply/2`
   should be pure. `describe/1` returns public, JSON-shaped provenance.
4. A native `Lemieux.Tool` implements `name/0`, `description/0`, `schema/0`
   and `run/2`. Declare optional `read_only?/0` and `parallel_safe?/0` only
   when their claims are true; both default to false. Keep schema and tool
   result honest; return `{:ok, text}` or `{:error, reason}`. Register the
   module in the extension's tool catalog before advertising it.
5. Run the target project's focused tests and compile with warnings as errors.
   Format and run its required final gate, if it has one. Report the result
   separately from any live provider check.

## Use it

An embedded host adds the Mix project as a dependency and applies the compiled
module with `Lemieux.Harness.assemble/2`. For the installed `lmx` binary, a
script extension is its directory under `~/.lmx/extensions/NAME`; a Mix project
runs `mix lmx.extension.build --name NAME` after it passes local checks. Either
loads with `lmx --extension NAME` or `lmx --extension-dir PATH`, and
`lmx extension list` says whether each installed one would load.

A compiled bundle records `extension_api` and must match the binary's OTP major
version and extension API, on the same or a newer Elixir of the same major; a
script only needs its Lemieux requirement to hold. Settings a person chooses
belong in `~/.lmx/config.json` under `"extension_options": {"NAME": {...}}`,
which survives a rebuild; the manifest's `options` are the defaults. Do not
silently activate it in personal config.

If the user asks for comparative model tuning, load `evaluate-extension`.
An Ixway route cannot predict its final billed target, so an explicit dollar
cap may stop before the first request. A request bound is available for an
authorized quota route; unknown dollars remain unknown.
