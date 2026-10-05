defmodule Lemieux.Asset.Registry do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Pure activation pointers and rollback history for asset versions.

  The registry is data, not a global process. A standalone host may serialize
  it and an embedded host may transact it in its own database. Both use the
  same rule: historical versions are immutable and rollback atomically moves
  the active pointer to a known version.
  """

  alias Lemieux.Asset.Proposal
  alias Lemieux.Asset.Version
  alias Lemieux.ID

  @type activation :: %{
          id: String.t(),
          action: :activate | :rollback,
          key: {Version.asset_type(), Version.scope(), String.t() | nil},
          version_id: String.t(),
          parent_id: String.t() | nil,
          rollback_target_id: String.t() | nil,
          at: DateTime.t()
        }
  @type t :: %__MODULE__{active: map(), history: [activation()]}
  defstruct active: %{}, history: []

  @doc "Returns an empty registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Activates an explicitly approved proposal."
  @spec activate(registry :: t(), proposal :: term()) ::
          {:ok, t(), activation()} | {:error, term()}
  def activate(%__MODULE__{} = registry, %Proposal{status: :approved, version: version}) do
    key = Version.identity(version)

    activation = %{
      id: "activation_" <> ID.generate(),
      action: :activate,
      key: key,
      version_id: version.id,
      parent_id: version.parent_id,
      rollback_target_id: version.rollback_target_id,
      at: DateTime.utc_now()
    }

    {:ok,
     %{
       registry
       | active: Map.put(registry.active, key, version),
         history: registry.history ++ [activation]
     }, activation}
  end

  def activate(%__MODULE__{}, %Proposal{}), do: {:error, :approval_required}

  def activate(%__MODULE__{}, _discovery_or_other_object),
    do: {:error, :approved_asset_proposal_required}

  @doc "Moves an active pointer to the recorded rollback target."
  @spec rollback(registry :: t(), activation :: activation(), target :: Version.t()) ::
          {:ok, t(), activation()} | {:error, term()}
  def rollback(%__MODULE__{} = registry, activation, %Version{} = target) do
    if activation.rollback_target_id == target.id and activation.key == Version.identity(target) do
      record = %{
        id: "activation_" <> ID.generate(),
        action: :rollback,
        key: activation.key,
        version_id: target.id,
        parent_id: activation.version_id,
        rollback_target_id: target.rollback_target_id,
        at: DateTime.utc_now()
      }

      {:ok,
       %{
         registry
         | active: Map.put(registry.active, activation.key, target),
           history: registry.history ++ [record]
       }, record}
    else
      {:error, :invalid_rollback_target}
    end
  end

  @doc "Returns the active version for a stable asset key."
  @spec active(registry :: t(), key :: tuple()) :: Version.t() | nil
  def active(%__MODULE__{} = registry, key), do: Map.get(registry.active, key)
end
