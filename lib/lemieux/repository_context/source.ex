defmodule Lemieux.RepositoryContext.Source do
  @moduledoc """
  A host-selected semantic index or language-server adapter.

  The callback runs in a disposable, deadline-bound worker. Its request carries
  `:repository` (an opaque host id), `:operation`, `:query`, `:path`,
  `:max_candidates` and an absolute monotonic `:deadline_ms`. It receives no
  session or provider handle. Hosts own server selection, startup, credentials,
  index updates and cancellation of work outside the worker. Monitor the worker
  when forwarding asynchronous requests; killing a BEAM worker cannot cancel an
  unrelated server request on its own. Adapters are trusted executable host code,
  not a sandbox for repository plugins.

  Return a batch with `:items` (an enumerable), `:revision` (an index version),
  `:indexed_at` (ISO 8601), and `:complete?`. Items are maps with `:kind`
  (`definition`, `reference`, `dependency`, `symbol` or `diagnostic`), a relative
  `:path`, one-based `:line`, `:symbol`, and the `:digest` (lowercase SHA-256) of
  the exact source bytes used by the index. Optional `:container`, `:message`
  and `:severity` describe an edge or diagnostic. Never substitute the digest of
  a newer file for the one a language server actually analyzed. Unsaved buffers
  that differ from the environment's files are withheld as stale.

  The consumer checks permissions and source digests before disclosure and
  bounds enumeration, reads and output. A file digest proves a source location
  still matches; it does not prove that an index covered every file or resolved
  dynamic calls correctly. `:complete?` is the adapter's coverage claim, retained
  separately from per-file freshness. Raw adapter errors are never disclosed.
  Filter/rank queries in the adapter before yielding candidates so unrelated
  records do not consume the disclosure allowance; the worker deadline also
  bounds this adapter-side selection.
  """

  @type request :: %{
          repository: String.t(),
          operation: String.t(),
          query: String.t(),
          path: String.t() | nil,
          max_candidates: pos_integer(),
          deadline_ms: integer()
        }
  @type batch :: %{
          items: Enumerable.t(),
          revision: String.t(),
          indexed_at: String.t(),
          complete?: boolean()
        }

  @callback query(state :: term(), request :: request()) :: {:ok, batch()} | {:error, term()}
end
