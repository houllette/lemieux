defmodule Lemieux.A2A.Skill do
  @moduledoc """
  One thing an agent will do for another agent.

  A2A's skills are what a caller reads to decide whether this agent is the
  right one to ask, so they are written for a reader who knows nothing about
  the agent's repository or its operator.

  ## Derived, not declared

  `from_tools/1` builds the list from what a remote task would actually be
  given rather than from a configuration somewhere else. A card and a policy
  that are maintained separately drift, and the direction they drift is always
  the same: the card keeps promising a thing the policy stopped allowing, and
  the failure surfaces as a refusal to a caller that had planned around it.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()]
        }

  defstruct [:id, :name, :description, tags: []]

  @doc "The skill as JSON."
  @spec to_json(skill :: t()) :: map()
  def to_json(%__MODULE__{} = skill),
    do: %{
      "id" => skill.id,
      "name" => skill.name,
      "description" => skill.description,
      "tags" => skill.tags
    }

  @doc "A skill a peer published."
  @spec from_json(json :: map()) :: t()
  def from_json(json) when is_map(json),
    do: %__MODULE__{
      id: json["id"],
      name: json["name"],
      description: json["description"],
      tags: Map.get(json, "tags", [])
    }

  @doc """
  The skills a session offers other agents.

  One skill, deliberately, and it is the honest one: this agent will answer
  questions about the repository it is working in, by reading it. Enumerating
  the underlying tools instead would describe the mechanism rather than the
  service, and a caller does not want to know that `read` exists — it wants to
  know whether asking is worth its time.
  """
  @spec from_tools(snapshot :: map()) :: [t()]
  def from_tools(%{tools: tools} = snapshot) do
    if Enum.any?(tools, &(Lemieux.Tool.name(&1) == "read")),
      do: repository_skill(snapshot),
      else: []
  end

  def from_tools(snapshot), do: repository_skill(snapshot)

  defp repository_skill(snapshot) do
    [
      %__MODULE__{
        id: "ask",
        name: "Answer questions about this codebase",
        description:
          "Ask about the code in #{Path.basename(snapshot.cwd)}: how something works, " <>
            "where something lives, what a change would touch. Answers are read from the " <>
            "working tree as it is now. This agent will not change anything on your behalf.",
        tags: ["code", "read-only", "question-answering"]
      }
    ]
  end
end
