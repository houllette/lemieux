defmodule Lemieux.Subagent.Request do
  @moduledoc "A validated definition and task submitted as one child request."

  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Task

  @type t :: %__MODULE__{definition: Definition.t(), task: Task.t()}
  @enforce_keys [:definition, :task]
  defstruct [:definition, :task]

  @doc "Builds and validates a child request."
  @spec new(definition :: Definition.t(), task :: Task.t()) :: t()
  def new(%Definition{} = definition, %Task{} = task) do
    %__MODULE__{definition: Definition.validate!(definition), task: Task.validate!(task)}
  end

  @doc "The live duplicate-work key for this definition, brief, and snapshot."
  @spec duplicate_key(request :: t()) :: {String.t(), String.t(), String.t()}
  def duplicate_key(%__MODULE__{} = request) do
    {
      Definition.digest(request.definition),
      Task.digest(request.task),
      request.task.snapshot |> JSON.encode!() |> hash()
    }
  end

  defp hash(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
