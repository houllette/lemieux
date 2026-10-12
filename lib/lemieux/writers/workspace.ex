defmodule Lemieux.Writers.Workspace do
  @moduledoc """
  Host-owned isolated environments, patch custody and integration.

  Preparation must either return an exclusively owned lease or clean up its
  partial allocation. Callbacks must be bounded. Release is idempotent and
  must remove only that lease. Export verifies scope, preserves the complete
  report and returns immutable, revision-bound evidence. Integration owns
  serialization, stale-base checks, project checks and interruption recovery.

  A worktree separates files, not security. Hosts granting commands must also
  provide a sandbox which enforces their scope. Neither the coordinator nor
  a transcript can turn a local shell into one.
  """
  alias Lemieux.Environment
  alias Lemieux.Writers.Artifact
  alias Lemieux.Writers.Plan

  @enforce_keys [:id, :cwd, :environment, :base_revision]
  defstruct [:id, :cwd, :environment, :base_revision, :lease, commands?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          cwd: Path.t(),
          environment: Environment.t(),
          base_revision: String.t(),
          lease: term(),
          commands?: boolean()
        }
  @type adapter :: {module(), term()}
  @type check :: (Path.t() -> {:ok, map()} | {:error, term()})

  @callback prepare(state :: term(), group_id :: String.t(), plan :: Plan.t()) ::
              {:ok, t()} | {:error, term()}
  @callback export(
              state :: term(),
              workspace :: t(),
              plan :: Plan.t(),
              result :: map(),
              evidence :: map()
            ) :: {:ok, Artifact.t()} | {:error, term()}
  @callback release(state :: term(), workspace :: t()) :: :ok | {:error, term()}
  @callback integrate(
              state :: term(),
              artifacts :: [Artifact.t()],
              checks :: check(),
              authorize :: (-> :ok | {:error, term()})
            ) ::
              {:ok, map()} | {:error, term()}

  @doc false
  @spec call(adapter :: adapter(), callback :: atom(), arguments :: [term()]) :: term()
  def call({module, state}, callback, arguments), do: apply(module, callback, [state | arguments])
end
