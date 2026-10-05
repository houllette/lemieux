defmodule Lemieux.A2A.Task do
  @moduledoc """
  One unit of work an agent is doing for somebody else, in A2A's terms.

  [A2A](https://a2a-protocol.org) is the protocol for agents talking to other
  agents, where MCP is the protocol for an agent talking to tools. lemieux is
  already an MCP client; this is the other axis.

  The serving projection reaches working, input-required and terminal task
  states. Authentication is performed by the HTTP host before admission;
  auth-required and rejected remain readable states for foreign peers. A task
  is a protocol projection over a fresh session, not a durable workflow engine.

  ## The states, and why the distinction that matters is not "done"

  A2A splits the non-active states in two, and the split is the useful part:

    * **interrupted** — `input_required`, `auth_required`. The task is not
      over. Somebody is being asked for something, and sending it continues
      the same task rather than starting another. A caller that treated these
      as failures would abandon work that was one answer from finishing.
    * **terminal** — `completed`, `failed`, `canceled`, `rejected`. No further
      message is accepted, and a caller that keeps waiting on one waits
      forever.

  `terminal?/1` and `interrupted?/1` are the two questions worth asking, which
  is why they are functions here rather than comparisons spread across the
  callers.

  ## Naming

  The states are atoms in Elixir's idiom — `:input_required` — and go on the
  wire as the protocol spells them. `from_wire/1` and `to_wire/1` are the only
  places that know both, so a binding never has to.
  """

  alias Lemieux.A2A.Message

  @typedoc """
  Where a task stands.

  The protocol's eight states, unabridged: dropping the ones lemieux cannot
  currently reach would make this a description of today's implementation
  rather than of the protocol, and a peer is entitled to send any of them.
  """
  @type state ::
          :submitted
          | :working
          | :input_required
          | :auth_required
          | :completed
          | :failed
          | :canceled
          | :rejected

  @typedoc "A task, as both sides of a conversation see it."
  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t() | nil,
          state: state(),
          message: String.t() | nil,
          status_message: map() | nil,
          timestamp: String.t() | nil,
          artifacts: [map()],
          history: [map()],
          metadata: map()
        }

  defstruct [
    :id,
    :context_id,
    :message,
    :status_message,
    :timestamp,
    state: :submitted,
    artifacts: [],
    history: [],
    metadata: %{}
  ]

  @active [:submitted, :working]
  @interrupted [:input_required, :auth_required]
  @terminal [:completed, :failed, :canceled, :rejected]

  @wire %{
    submitted: "TASK_STATE_SUBMITTED",
    working: "TASK_STATE_WORKING",
    input_required: "TASK_STATE_INPUT_REQUIRED",
    auth_required: "TASK_STATE_AUTH_REQUIRED",
    completed: "TASK_STATE_COMPLETED",
    failed: "TASK_STATE_FAILED",
    canceled: "TASK_STATE_CANCELED",
    rejected: "TASK_STATE_REJECTED"
  }

  @doc "Every state the protocol defines."
  @spec states() :: [state()]
  def states, do: @active ++ @interrupted ++ @terminal

  @doc """
  Whether the task is over and will accept nothing further.

  The question a caller asks before deciding whether to keep waiting.
  """
  @spec terminal?(task :: t() | state()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: terminal?(state)
  def terminal?(state) when state in @terminal, do: true
  def terminal?(state) when state in @active or state in @interrupted, do: false

  @doc """
  Whether the task is waiting on somebody rather than finished.

  The distinction `terminal?/1` alone cannot make: a task that stopped is not
  necessarily a task that failed, and answering it resumes the same task.
  """
  @spec interrupted?(task :: t() | state()) :: boolean()
  def interrupted?(%__MODULE__{state: state}), do: interrupted?(state)
  def interrupted?(state) when state in @interrupted, do: true
  def interrupted?(state) when state in @active or state in @terminal, do: false

  @doc """
  Whether the task is still being worked on, with nobody waited for.
  """
  @spec active?(task :: t() | state()) :: boolean()
  def active?(%__MODULE__{state: state}), do: active?(state)
  def active?(state) when state in @active, do: true
  def active?(state) when state in @interrupted or state in @terminal, do: false

  @doc """
  Moves a task to `state`, or says why it cannot go there.

  A terminal state is final, and this is where that is enforced rather than
  in each caller: an agent that reported `completed` and then `failed` would
  have a peer holding two different answers to the same question, with no way
  to know which arrived second.

  An interrupted task *may* move on — that is what answering it does.
  """
  @spec transition(task :: t(), state :: state(), message :: String.t() | nil) ::
          {:ok, t()} | {:error, String.t()}
  def transition(%__MODULE__{state: from} = task, to, message \\ nil) do
    cond do
      to not in states() ->
        {:error, "#{inspect(to)} is not a task state"}

      terminal?(from) ->
        {:error, "the task is already #{from}, which is final; it cannot become #{to}"}

      true ->
        {:ok,
         %{
           task
           | state: to,
             message: message,
             status_message: nil,
             timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
    end
  end

  @doc """
  What lemieux's own end-of-turn reason means in the protocol's terms.

  The mapping is the whole reason the vocabulary transfers, so it lives in one
  place rather than being made again at each boundary. `:max_turns` and
  `:no_progress` are **failures** rather than completions: the agent stopped
  because it was not getting anywhere, and a peer told `completed` would treat
  a half-finished job as done.
  """
  @spec from_finish(reason :: term()) :: state()
  def from_finish(:stop), do: :completed
  def from_finish(:cancelled), do: :canceled
  def from_finish(:max_turns), do: :failed
  def from_finish(:no_progress), do: :failed
  def from_finish(_other), do: :failed

  @doc """
  The task as JSON, in the protocol's shape.
  """
  @spec to_json(task :: t()) :: map()
  def to_json(%__MODULE__{} = task) do
    status = %{"state" => to_wire(task.state)}

    status =
      if task.status_message || task.message,
        do:
          Map.put(
            status,
            "message",
            task.status_message || Message.agent(task.message)
          ),
        else: status

    status =
      if status["message"] do
        message = status["message"] |> Map.put("taskId", task.id)

        message =
          if task.context_id, do: Map.put(message, "contextId", task.context_id), else: message

        Map.put(status, "message", message)
      else
        status
      end

    status = if task.timestamp, do: Map.put(status, "timestamp", task.timestamp), else: status

    %{
      "id" => task.id,
      "status" => status,
      "artifacts" => artifacts(task),
      "history" => task.history,
      "metadata" => task.metadata
    }
    |> then(fn json ->
      if task.context_id, do: Map.put(json, "contextId", task.context_id), else: json
    end)
  end

  @doc "Reads a validated A2A 1.0 task without raising on malformed peer data."
  @spec from_json(json :: term()) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"id" => id, "status" => %{"state" => wire} = status} = json)
      when is_binary(id) and byte_size(id) > 0 do
    with {:ok, state} <- from_wire(wire),
         true <- Message.optional?(json, "contextId", &is_binary/1),
         true <- Message.optional?(json, "metadata", &is_map/1),
         true <- Message.optional?(status, "timestamp", &Message.timestamp?/1),
         true <- Message.optional?(status, "message", &(Message.validate(&1) == :ok)),
         true <- Message.optional?(json, "artifacts", &valid_artifacts?/1),
         true <- Message.optional?(json, "history", &valid_history?/1) do
      message = status["message"]

      {:ok,
       %__MODULE__{
         id: id,
         context_id: json["contextId"],
         state: state,
         message: message && Message.text(message),
         status_message: message,
         timestamp: status["timestamp"],
         artifacts: Map.get(json, "artifacts", []),
         history: Map.get(json, "history", []),
         metadata: Map.get(json, "metadata", %{})
       }}
    else
      _ -> {:error, "the peer sent an invalid task status, message, artifacts or history"}
    end
  end

  def from_json(_json), do: {:error, "the peer sent something that is not a task"}

  @doc "Text produced by a task, including the legacy in-memory convenience shape."
  @spec text(task :: t()) :: String.t()
  def text(%__MODULE__{artifacts: artifacts}) do
    Enum.map_join(artifacts, "\n", fn
      %{"text" => text} -> text
      %{"parts" => parts} -> Enum.map_join(parts, "", &Map.get(&1, "text", ""))
      _ -> ""
    end)
  end

  @doc "Canonical artifacts for serialization and streaming."
  @spec artifacts(task :: t()) :: [map()]
  def artifacts(%__MODULE__{} = task) do
    task.artifacts
    |> Enum.with_index()
    |> Enum.map(fn
      {%{"text" => text}, index} ->
        %{"artifactId" => "#{task.id}:#{index}", "parts" => [%{"text" => text}]}

      {artifact, _index} ->
        artifact
    end)
  end

  defp valid_artifacts?(artifacts) when is_list(artifacts) do
    Enum.all?(artifacts, fn
      %{"artifactId" => id, "parts" => parts} when is_binary(id) and is_list(parts) ->
        id != "" and parts != [] and Enum.all?(parts, &Message.part?/1)

      _ ->
        false
    end)
  end

  defp valid_artifacts?(_artifacts), do: false

  defp valid_history?(history) when is_list(history),
    do: Enum.all?(history, &(Message.validate(&1) == :ok))

  defp valid_history?(_history), do: false

  @doc """
  The state's name on the wire.
  """
  @spec to_wire(state :: state()) :: String.t()
  def to_wire(state) when is_map_key(@wire, state), do: Map.fetch!(@wire, state)

  @doc """
  The state a peer named, whatever spelling it used.

  Both the enum form (`TASK_STATE_INPUT_REQUIRED`) and the older hyphenated
  one (`input-required`) are accepted, because a peer may predate the version
  this was written against and refusing to read it would be refusing to
  interoperate over spelling.
  """
  @spec from_wire(name :: String.t()) :: {:ok, state()} | :error
  def from_wire(name) when is_binary(name) do
    normalised = name |> String.replace_prefix("TASK_STATE_", "") |> String.replace("-", "_")

    case Enum.find(states(), &(Atom.to_string(&1) == String.downcase(normalised))) do
      nil -> :error
      state -> {:ok, state}
    end
  end

  def from_wire(_name), do: :error
end
