defmodule Lemieux.Subagent.Group.Ref do
  @moduledoc "An opaque capability naming one foreground fan-out group."

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t(),
          supervisor: atom(),
          control_token: reference()
        }

  @enforce_keys [:id, :parent_id, :supervisor, :control_token]
  defstruct [:id, :parent_id, :supervisor, :control_token]
end
