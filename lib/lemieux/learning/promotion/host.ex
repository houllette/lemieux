defmodule Lemieux.Learning.Promotion.Host do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Atomic host installation of a promotion transition. Serialize policy changes,
  registry changes, canary feedback and runtime installation in one authority
  domain. Call the transition once against the current owned state. It returns
  a proposed state, effective harness, receipt and a fresh authority recheck.
  Complete assembly/restart preparation, call that recheck, then commit all
  three together. An error exposes none of the candidate runtime.

  A host that mutates external runtimes must persist intent before effects,
  retain the exact prior version/harness, restore them on failure and reconcile
  an interrupted transaction before serving requests. Unknown restoration must
  block use, never claim rollback success or automatically replay effects.
  Persist audit records and quarantine atomically with the pointer. Serialized
  state supplies provenance only: mount current host authority and current base
  afresh, and call `Promotion.current/2` on resume. Never deserialize callbacks.
  """
  alias Lemieux.Harness
  alias Lemieux.Learning.Promotion

  @callback transact(
              state :: term(),
              transition :: (Promotion.state() ->
                               {:ok, Promotion.state(), Harness.t(), map(),
                                (-> :ok | {:error, term()})}
                               | {:error, term()})
            ) ::
              {:ok, Harness.t(), map()} | {:error, term()}
end
