defmodule Lemieux.Subagent.Snapshot do
  @moduledoc "A live, bounded view of one child and its durable transcript reference."

  alias Lemieux.Subagent.Result

  @type t :: %__MODULE__{
          id: String.t(),
          group_id: String.t(),
          parent_id: String.t(),
          status: :queued | :running | Result.status(),
          definition_id: String.t(),
          transcript_id: String.t(),
          input: map(),
          session: map() | nil,
          result: Result.t() | nil
        }

  @enforce_keys [:id, :group_id, :parent_id, :status, :definition_id, :transcript_id, :input]
  defstruct [
    :id,
    :group_id,
    :parent_id,
    :status,
    :definition_id,
    :transcript_id,
    :input,
    :session,
    :result
  ]
end
