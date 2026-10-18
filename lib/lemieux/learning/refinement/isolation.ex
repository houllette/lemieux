defmodule Lemieux.Learning.Refinement.Isolation do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Host-owned effect isolation for task-local probes. A copied transcript or
  directory alone is not a sandbox. The host must confine all tool, hook,
  verification and subprocess effects, supply fresh equivalent inputs, and
  destroy the lease (including running work) on release. Acquisition is bounded;
  release must finish within five seconds. Each lease also supplies the current
  effective `runtime_identity` for its actual workspace. Distinct workspace
  paths retain distinct qualifications; the host attests input equivalence
  instead of normalizing away those differences. Private handles stay
  in memory; only attested identities enter evidence.
  """
  alias Lemieux.Benchmark.Task

  @callback inspect(state :: term()) :: {:ok, map()} | {:error, term()}
  @callback acquire(state :: term(), id :: String.t(), bindings :: map()) ::
              {:ok,
               %{task: Task.t(), session: keyword(), id: String.t(), runtime_identity: map()}}
              | {:error, term()}
  @callback validate(state :: term(), lease :: map(), bindings :: map()) :: :ok | {:error, term()}
  @callback release(state :: term(), lease :: map()) :: term()
end
