defmodule Lemieux.Asset.Proposal do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Human-review state for one immutable asset version.

  Phase one deliberately permits no implicit approval. Later hosts may apply
  their own promotion policy, but it still has to produce the same explicit
  approval/activation evidence instead of mutating a policy file silently.
  """

  alias Lemieux.Asset.Version
  alias Lemieux.ID

  @type status :: :proposed | :approved | :activated | :rejected
  @type t :: %__MODULE__{
          id: String.t(),
          version: Version.t(),
          status: status(),
          approved_by: map() | nil,
          approved_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :version]
  defstruct [:id, :version, :approved_by, :approved_at, status: :proposed]

  @doc "Creates an unapproved proposal."
  @spec new(version :: Version.t()) :: t()
  def new(%Version{} = version),
    do: %__MODULE__{id: "proposal_" <> ID.generate(), version: version}

  @doc "Records explicit approval by a named actor."
  @spec approve(proposal :: t(), actor :: map()) :: {:ok, t()} | {:error, term()}
  def approve(%__MODULE__{status: :proposed} = proposal, actor) when is_map(actor) do
    {:ok,
     %{
       proposal
       | status: :approved,
         approved_by: actor,
         approved_at: DateTime.utc_now()
     }}
  end

  def approve(%__MODULE__{}, _actor), do: {:error, :proposal_not_pending}
end
