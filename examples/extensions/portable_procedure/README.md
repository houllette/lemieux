# Portable procedure

An owner-supplied native Mix agent loads a typed procedure through Lemieux's
ordinary session and skill tool, writes a verifiable artifact, and restores its
original harness. It uses only `Lemieux.Providers.Scripted`; it cannot select a
hosted provider. Installing the dependency starts no Lemieux runtime.

Run the complete review command from the repository root:

```sh
mise exec -- mix run examples/portable_asset.exs --output tmp/portable-asset-review
```

The output directory must be new. An interrupted or failed run keeps its evidence.
The command copies this project's selected source files verbatim, materializes
the procedure data, exports through `Lemieux.Learning.Extension.Export`, and
freezes two builds of the exported package. Each episode executes in a fresh
consumer process with its own session. The adapted episode reads
`references/rules.json` through the actual skill tool before constructing its
write call; changing or withholding that file changes the observed outcome.
The command also creates a fresh Mix consumer with the exported project as a
path dependency, resolves against the checkout's lock, compiles and runs it,
and compares its installed result and asset identity with the frozen run.
Dependency resolution can use Hex; no step calls a hosted model.

| Episode | Normalized records | Scripted requests | Active procedure |
| --- | --- | ---: | --- |
| Original harness | `["alpha","beta"]` | 2 | None |
| Approved procedure | `["alpha","","beta"]` | 3 | Exact exported asset ID/digest |
| Original harness after undo | `["alpha","beta"]` | 2 | None |

`review.json` binds the exact driver, package inventory, frozen builds, observed
asset identity, artifacts, request counts and rollback checks. Inspect `package/`
for the installable native source and `before/`, `applied/`, `after-undo/` for
the actual files. `consumer/installed.json` and its command logs retain the
fresh installation evidence, resolved lock digest and runtime versions, including
the absence of an application callback on the library and native example.
Reassembling the original harness removes the adaptation;
it does not undo files a completed task already wrote.

The source template is under `procedure/`. The runtime tree under
`priv/learned/` is created inside the output project, so no generated asset,
approval or session history is committed to this example. The native manifest
declares every runtime file and its transitive dependencies.

## Install the exported native project

Use a fresh consumer with a path dependency on the emitted `package` directory:

```elixir
defp deps do
  [{:portable_procedure, path: "/absolute/path/to/portable-asset-review/package"}]
end
```

This unreleased example requires the current checkout. Set
`LEMIEUX_EXTENSION_BASE` to the checkout's absolute path before `mix deps.get`.
The exported `mix.exs` is owner-supplied source and reads that host input; the
package contains no compiled dependencies or credentials.

Pass a scripted profile with model `test:portable-procedure`, tools
`["read", "write"]`, and options `enabled: true` and `asset_sha256` matching
the retained review report (JSON keys are strings). `PortableProcedure.configure/1`
validates the installed source against the current host context before its
explicit, example-only digest approval. `Lemieux.Agent.run/3` then accepts a
workspace containing `records.json` and the returned runtime options. Override
`sessions_dir:` with storage owned by that invocation. See the
[embedding/export contract](../../../docs/harness-learning.md#typed-candidates-and-portable-exports)
for supplying a live host's own approval rather than this offline example policy.

## Qualification and review

The package and report remain **unassessed**. The deterministic baseline is
deliberately missing the empty-record rule; this demonstrates dataflow and
packaging mechanics, not learned efficacy, statistical independence, model
transfer or automatic promotion. The root confirmation regression separately
exercises the sealed comparison and qualified export APIs with explicit fixture
evidence. No fixture receipt is presented as real release evidence here.

The command reports every missing CodeGate category, including microVM and
held-out evidence. It never manufactures passing gates or reviewer approval.
A qualified native export still needs the existing independent confirmation
workflow plus complete byte-bound CodeGate evidence and human review. A real
host obtains fresh scope, runtime, permission and approval inputs on each use.
The source's checksums grant no authority.

Run the example's own gate from the root:

```sh
scripts/check_example.sh portable_procedure
```

The root suite also executes the documented review command, verifies its report
and package, and checks that rerunning into the same directory preserves the
original evidence. The full local gate is `mix precommit.full`.

Example code is Apache-2.0 licensed, like Lemieux; its [LICENSE](LICENSE)
is included in the exported native package.
