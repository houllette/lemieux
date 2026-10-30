defmodule Lemieux.Asset.Proposal do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  Explicit review state for one immutable asset version.

  No helper implicitly approves a proposal. `Learning.Promotion` may record
  approval by a named host policy actor, with its immutable policy digest,
  after checking current authority and evidence. Human and policy approvals
  produce the same explicit approval/activation records.
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
