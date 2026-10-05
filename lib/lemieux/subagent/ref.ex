defmodule Lemieux.Subagent.Ref do
  @moduledoc """
  An opaque capability naming one child session.

  The random `control_token` is intentionally distinct from the public child
  id. A pid or transcript id is discovery, not authorization; live inspect,
  steer, and cancel operations require the capability returned at admission.
  Hosts should keep it behind their tenant authorization boundary.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          group_id: String.t(),
          parent_id: String.t(),
          supervisor: atom(),
          control_token: reference()
        }

  @enforce_keys [:id, :group_id, :parent_id, :supervisor, :control_token]
  defstruct [:id, :group_id, :parent_id, :supervisor, :control_token]
end
