defmodule Lemieux.Provider.Admission do
  @moduledoc """
  Who may send a provider request now, and in what order: the seam a session
  checks a lease out from before every model call.

  This behaviour owns **admission and fairness** — bounding how many requests
  share a credential or rate domain at once, queueing the rest so one busy
  root cannot starve another, and holding back the requests that follow a
  refusal for as long as the provider's `retry-after` asked. It does not own
  **retries**. The request that saw the limit stays a failed provider call in
  its transcript; whether to send it again is `Lemieux.Session`'s
  `:provider_retry` policy, and deciding which failures are worth it is
  `Lemieux.Provider.Error.transient?/2`. The two are kept apart because an
  admission layer that also retried would repeat a request the session had
  already accounted for, and nothing in the transcript would say so.

  `Lemieux.ProviderLimiter` is the shipped implementation and what every
  mount gets unless it says otherwise. Before this behaviour existed the
  session and the supervisor named that module literally, so a host could
  swap the *process* — pass a shared limiter pid — but never the *algorithm*.
  A multi-tenant host that meters by account rather than by root session, or
  one whose gateway already does the queueing and wants admission to be a
  formality, passes `provider_limiter: {MyAdmission, opts}` to
  `Lemieux.Supervisor`; the loop then calls the wrappers here with the pair
  `Lemieux.Supervisor.provider_admission/1` returns.

  ## The contract

  An implementation is a `{module, ref}` pair. The supervisor starts `module`
  as a child through its `child_spec/1` — any `use GenServer` or `use Agent`
  provides one — with `:name` set to `Lemieux.Supervisor.provider_limiter/1`
  for the mount, and that name is the `ref` every callback receives. A lease
  is whatever `c:checkout/4` returned; the loop never looks inside it and
  hands it back unchanged to `c:reconcile/2` and `c:release/1`.

  Callbacks run in the session's supervised provider task, never in the
  session process, so `c:checkout/4` may block for as long as it needs: a
  waiting request is a waiting task, and cancelling the request kills the
  task. That is also why an implementation must notice an owner that died
  without calling `c:release/1` — the shipped limiter monitors the caller —
  because a lease that leaked would hold its slot forever.
  """

  @typedoc "An implementation module paired with the ref its callbacks take."
  @type t :: {module(), ref :: term()}

  @typedoc "The rate domain a request belongs to. Opaque to the loop."
  @type key :: term()

  @typedoc "The root session whose requests share fair queueing."
  @type root_id :: String.t()

  @typedoc "Whatever `c:checkout/4` returned. Opaque to the loop."
  @type lease :: term()

  @doc """
  Waits for admission and returns a lease, or refuses the request outright.

  `estimated_tokens` is the request's pessimistic size, for implementations
  that meter tokens; the actual count arrives later through `c:reconcile/2`.
  An `{:error, reason}` is final for this request — the session reports it as
  `{:provider_admission, reason}` rather than waiting — so refuse only what
  could never be admitted, such as a request larger than a whole bucket.
  """
  @callback checkout(
              ref :: term(),
              key :: key(),
              root_id :: root_id(),
              estimated_tokens :: non_neg_integer()
            ) :: {:ok, lease()} | {:error, term()}

  @doc "Records the tokens a live lease actually used, before it is released."
  @callback reconcile(lease :: lease(), actual_tokens :: non_neg_integer()) :: :ok

  @doc "Gives a lease back. Must be harmless to call twice."
  @callback release(lease :: lease()) :: :ok

  @doc "Holds new grants for `key` until `retry_after_ms` has passed."
  @callback penalize(ref :: term(), key :: key(), retry_after_ms :: non_neg_integer()) :: :ok

  @doc "Checks a lease out through the implementation in `admission`."
  @spec checkout(
          admission :: t(),
          key :: key(),
          root_id :: root_id(),
          estimated_tokens :: non_neg_integer()
        ) :: {:ok, lease()} | {:error, term()}
  def checkout({module, ref}, key, root_id, estimated_tokens) when is_atom(module),
    do: module.checkout(ref, key, root_id, estimated_tokens)

  @doc "Reports a lease's actual usage through the implementation in `admission`."
  @spec reconcile(admission :: t(), lease :: lease(), actual_tokens :: non_neg_integer()) :: :ok
  def reconcile({module, _ref}, lease, actual_tokens) when is_atom(module),
    do: module.reconcile(lease, actual_tokens)

  @doc "Releases a lease through the implementation in `admission`."
  @spec release(admission :: t(), lease :: lease()) :: :ok
  def release({module, _ref}, lease) when is_atom(module), do: module.release(lease)

  @doc "Applies a provider's retry-after through the implementation in `admission`."
  @spec penalize(admission :: t(), key :: key(), retry_after_ms :: non_neg_integer()) :: :ok
  def penalize({module, ref}, key, retry_after_ms) when is_atom(module),
    do: module.penalize(ref, key, retry_after_ms)
end
