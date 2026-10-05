# Native security extension example

- **What it shows:** wrapping an external tool (Nmap) as bounded,
  model-callable tools, plus a host hook that keeps every scan inside the
  targets you configured.
- **Runs offline?** Yes. `mix test` needs no key and scans nothing: the tests
  record the commands instead of running them.
- **Needs:** for a live session, `LMX_MODEL` and that provider's key. Nmap
  only if you actually scan, and only targets listed in `config/config.exs`.

This ordinary Mix package ships reusable Elixir code, two model-callable tools,
and a session agent. It is an example, not a vetted vulnerability scanner. No
scan runs when the package is loaded.

- `Pipeline.nmap_command/2` validates a single IPv4 target and up to 128 explicit
  ports, then constructs a bounded command. `Tools.Nmap` runs it through the
  host's normal environment with a 30-second timeout and bounded output.
- `Pipeline.assess_ports/1` is a pure policy check, also exposed by
  `Tools.AssessPorts`. Call it directly in deterministic Elixir workflows or
  let the model call it. A policy flag is not a confirmed vulnerability.
- `Scope` decides which hosts `nmap_scan` may touch (below).
- `tool_registry/0` supplies compiled implementations; profile strings only
  select those names. `configure/2` and `cli/2` use the same registry.

Nmap must already be installed in the execution environment. The wrapper uses
[TCP connect scanning](https://nmap.org/book/man-port-scanning-techniques.html),
[explicit ports](https://nmap.org/book/man-port-specification.html) and
[XML output](https://nmap.org/book/man-output.html). It does not install Nmap
or run privileged shell commands.

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
export LMX_MODEL=your_provider:your_model
mix deps.get
mix test
mix run -e 'SecurityExample.cli()'
mix run -e 'SecurityExample.cli(["run", "Review these observed ports: 22, 23, 443. Do not scan."])'
```

## Scan scope

The model chooses what to scan, and an instruction in the prompt is advice it
can ignore. So the target is checked where the host decides:
`SecurityExample.Scope` is a `before_tool_call` hook that denies any
`nmap_scan` call whose target is not listed, before the command is built. The
denial is the tool result the model reads, so it reports the target as out of
scope instead of believing it scanned it.

The list lives in `config/config.exs`:

```elixir
config :security_example, scan_targets: ["127.0.0.1"]
```

It holds single IPv4 addresses, and only the local machine to begin with. Add
an address only for a host you are authorized to scan. Both entry points apply
the scope: `cli/2` adds it as an extension after the session's other hooks,
and `configure/2`, which benchmarks and embedding hosts use, appends it to the
host's `:hooks`. Either takes a `scan_targets:` option in place of the
configuration. A host application that depends on this package sets the same
key in its own configuration; with nothing set, every scan is denied. A host
that wants a person to approve each scan as well adds its own approval hook
(`:pending`, see `Lemieux.Hooks`); the scope still applies after it.

## Budgets and dependencies

The example profile has a $1 cap; select appropriate bounds in `profile/1` or use
`Lemieux.Extension.Profile.quota(profile, requests)` for an authorized subscription.
Model credentials and environments belong to the host. The optional ex_ratatui
dependency enables this project's TUI. A host consuming the package as a dependency
must also opt into ex_ratatui for TUI use; headless use does not require it. This package's native
modules run in its compiled Mix host, not by loading JSON into an unrelated binary.

For Hex-backed auditors or parsers, add the dependency to this project's
`mix.exs`, run `mix deps.get`, and include the resulting `mix.lock` in
`lemieux-extension.json` before export. List all new tool/pipeline source files,
tests and required `priv` assets too. Standard Mix consumers resolve the dependencies;
export copies source and lockfiles, not `deps` or `_build`, and not
`config/config.exs`: a consumer configures `:scan_targets` itself. Dependencies
needing application startup or OS components must be started or provided
explicitly by the host.

Start with deterministic unit tests, then try the complete agent on
representative cases, failures included. Change the profile and the tool code
together, since the agent's behaviour depends on both. A multi-stage agent can
compose these functions around `Lemieux.Agent.Session.run/2`; it then owns its
cumulative budget and its interactive adapter. No workflow DSL is needed.
