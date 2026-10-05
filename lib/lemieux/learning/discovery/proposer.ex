defmodule Lemieux.Learning.Discovery.Proposer do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Behaviour for a host-supplied exploratory proposer.

  Implementations normally launch an ordinary fresh root `Lemieux.Session`
  using `Lemieux.Learning.Discovery.Shadow.fresh_session_options/2`. They receive
  no holdout, evaluator, registry, or activation capability from this
  behaviour.
  """

  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State

  @callback propose(plan :: Plan.t(), state :: State.t(), context :: map()) ::
              {:ok, Candidate.t(), map()} | :done | {:error, term()}
end
