# Bounded repository context

`Lemieux.Extensions.RepositoryContext` is an optional, read-only extension for
hosts that have a semantic index or language server. It adds one configured
`repository_context` tool with map, definitions, references, dependencies,
symbols, diagnostics and literal-search operations. The library and `lmx`
defaults stay unchanged. Nothing starts a language server or loads repository
configuration implicitly.

## An offline Elixir index

The host chooses the files, environment and access policy. This example uses
an explicit manifest; a host can obtain its manifest from its own workspace
inventory. The build only reads and parses source; it never compiles the
project, expands macros, loads dependencies or evaluates source.

```elixir
alias Lemieux.RepositoryContext.Elixir, as: Indexer
alias Lemieux.RepositoryContext.Index

environment = Lemieux.Environment.local()
root = File.cwd!()
paths = ["lib/my_app.ex", "lib/my_app/worker.ex"]
allowed = fn path -> String.starts_with?(path, "lib/") end

{:ok, index, metrics} =
  Indexer.build(environment, root, paths,
    allow: allowed,
    max_files: 500,
    max_source_bytes: 2_000_000,
    timeout_ms: 2_000
  )

{:ok, harness} =
  Lemieux.Harness.assemble(Lemieux.Harness.new(), [
    {Lemieux.Extensions.RepositoryContext,
     repositories: [
       %{id: "app", backend: {Index, index}, paths: paths,
         allow: fn path, _context -> allowed.(path) end}
     ],
     max_tokens: 4_096,
     max_source_bytes: 2_000_000,
     max_results: 30}
  ])
```

Pass `harness`, `environment` and `cwd: root` to the session. Assembly performs
no indexing or provider work. A profile without `read` receives no new reading
tools. Existing custom search tools are preserved, and the Search extension
supplies `grep` and `glob` beside `read` for ordinary navigation.

The model can request, for example:

```json
{"operation":"definitions","query":"MyApp.Worker.start","repositories":["app"],"path":"lib","max_tokens":2048}
```

Results include `repository:path:line`, current source text, the indexed file's
SHA-256, index revision and indexing timestamp. Structured evidence also
retains kind, symbol, container and selected diagnostic message/severity.
Maps rank exact query matches first, then referenced definitions, with stable
repository/path/line tie breaks. The incoming-reference score covers only the
bounded, authorized, verified candidate set; it is not a complete call graph.
Duplicate edges count once, and identical symbol names in different repositories
are separate nodes. Operation-specific snapshot queries filter record kinds
before applying the candidate cap.

The built-in index is **syntax only**. It reports definitions, syntactic calls,
module dependencies and parse errors. Aliases, imports, macros, generated code
and dynamic dispatch remain unresolved; these limits are shown in results.
Default arguments expose each syntactically callable arity, and calls in defaults
and guards are included. Explicit `Elixir.` module prefixes and lexical
`__MODULE__` aliases are resolved; other aliases remain unresolved.
Quoted forms and dynamic module definitions are omitted because their expansion
or destination cannot be established by syntax alone. Parsing emits no source
warnings to the host's stderr.
It handles identifier strings without interning repository names as VM atoms.

## Hosts choose indexes and language servers

Implement `c:Lemieux.RepositoryContext.Source.query/2` around an existing index or
host-managed language-server client. The request supplies an opaque repository
id, operation, query, optional relative path, candidate cap and monotonic
deadline. A host can translate a symbol query to workspace symbols and then
definition/reference requests, or select diagnostics from its own client.
The callback must be read-only and must enforce the host's indexing/read policy.
The consumer's path filter controls disclosure; it cannot sandbox trusted
adapter code executing in the same VM.

Return a batch like this, using the digest of the bytes actually analyzed:

```elixir
{:ok, %{
  revision: "host-index-generation-12",
  indexed_at: "2026-10-13T12:00:00Z",
  complete?: false,
  limitations: ["language server is still indexing dependencies"],
  items: [
    %{kind: "diagnostic", path: "lib/my_app.ex", line: 14,
      symbol: "MyApp", severity: "warning", message: "unused variable",
      digest: analyzed_source_sha256}
  ]
}}
```

`items` may be a lazy enumerable. Supported kinds are `definition`,
`reference`, `dependency`, `symbol` and `diagnostic`. Lines are one-based;
paths are relative and confined. An index timestamp is attribution, **not a
freshness guarantee**. The tool reads through the effective environment,
checks policy and compares digests before exposing a record. Changed, deleted,
denied, malformed or oversized sources are withheld with visible limitations.
Unsaved language-server buffers require matching source bytes in the host's
environment; a disk digest must never be substituted for a buffer digest.

Per-file verification does not establish that dependent files are current or
that a language server finished resolving the project. Adapters must report
partial coverage and transitive staleness explicitly. No language server is
bundled, downloaded or automatically launched by this feature.

## Budgets, cancellation and multiple repositories

Host limits cap candidate enumeration, returned items, source bytes, per-file
bytes, wall time and output. Model requests can lower the output allowance and
narrow repository/path scope; they cannot raise host limits or choose a new
root, environment or executable. `max_tokens` conservatively allows one UTF-8
byte per token, accounting for JSON string escaping. This is an intentionally
small allowance, not a measured tokenizer count. Audit fields have the normal
tool-result evidence budget separately.
The mandatory warning, adapter limitations and results all share that encoded
output allowance; notes omitted from the model text remain in audit metadata.

A worker deadline includes adapters, enumeration, source verification and
ranking. Cancelling the tool kills its worker; a guardian also kills it when
the awaiting caller dies. The worker has an 8-million-word heap ceiling in
addition to source and candidate limits. Environment callbacks must stream
bounded chunks to bound transient binary memory; a callback that materializes
a huge file before returning cannot be made streaming by the consumer.
Hosts must monitor the worker and forward cancellation to external clients;
worker termination alone cannot cancel an unrelated language-server request.

The default scope resolves against the invocation's current `cwd` and
environment. To authorize another repository, explicitly configure both its
absolute `root` and its own `environment`, alongside a unique id and policy.
The tool never interprets a model-supplied path as a new root. Source cache keys
include the repository id, and each invocation rechecks host policy.

Paths must use their canonical relative spelling. On the local environment,
both a symlink's requested path and its resolved in-workspace target must pass
the predicate; the read uses the resolved path. Custom environments own
physical alias resolution and must enforce the corresponding policy there.
Source verification is a bounded observation, not an atomic filesystem snapshot;
hosts needing protection against concurrent filesystem replacement enforce it
in their environment's read capability.

If semantics are missing or stale, a bounded literal search over `paths` uses
the same repository scope, permissions and remaining read/time budget. A
fallback is labeled as literal search and has current source digests. An
empty query or missing manifest yields search/read guidance. An incomplete
index can still return verified useful items; its coverage limit remains
visible. Budget exhaustion does not establish the absence of other results.
Literal matches share one result allowance across all files and repositories,
with one extra match to establish truncation. Fallback scans in the host's
repository and manifest order and stops once that allowance is full. A source
stream failure withholds that file and preserves other verified results.

## Updates and evaluation

Rebuild with `previous: index` to reuse unchanged parses. Every candidate file
is still read and hashed, including same-size edits. A new manifest removes
deleted or no-longer-authorized files. The host explicitly replaces backend
state or supplies a newly configured tool when resuming. No index is restored
as executable state from transcript evidence.
Duplicate retained manifest paths are read and parsed once; the manifest
examination cap still bounds repeated entries.

Run the offline mechanical comparison after compiling:

```sh
MIX_ENV=test mix run scripts/eval_repository_context.exs
```

It reports existing `grep` versus indexed definition/reference lookup on the
same source fixtures, cold indexing, warm parsing reuse, one-file update cost,
stale-context rejection/fallback, output bytes, elapsed time and retained
snapshot size. It asserts expected source locations and freshness behavior.
It makes no model calls and measures retrieval mechanics, **not agent task
quality**. Keep its JSON receipt with the exact source revision when comparing
changes.

Before enabling semantic context by default, use the host's paired evaluation
runner with a frozen corpus, identical models, tasks, tool/request/token/time
allowances and policy. Retain both arms, tool-schema tax, cold/update costs,
timeouts, stale-index mistakes, correctness graders, provider usage and costs.
Include multi-repository and denied-path cases. Hosted-model qualification and
production language-server adapters remain host work; offline receipts do not
establish a quality or cost win. See [evaluation gates](evaluations.md).

This feature adds no retrieval memory and leaves user-curated memory intact.
Any future persistent retrieval memory needs separate explicit scope, source
provenance, freshness, review and deletion controls.
