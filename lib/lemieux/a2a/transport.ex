defmodule Lemieux.A2A.Transport do
  @moduledoc """
  Host-owned bindings for explicit peer operations. Legacy callback arities
  remain supported. Optional option-bearing arities forward credentials and
  limits consistently; listing and subscription are advertised by each binding.
  """

  alias Lemieux.A2A.Card
  alias Lemieux.A2A.Task

  @typedoc "Where the other agent is, as its card's interface named it."
  @type address :: term()

  @doc """
  Asks the agent at `address` something, and returns the task it started.

  The task comes back in whatever state it reached, which is not necessarily
  a terminal one: an agent that needs something from the caller answers
  `input_required` rather than guessing, and the caller continues by sending
  another message with the same `task_id`.
  """
  @callback send_message(address :: address(), message :: map(), opts :: keyword()) ::
              {:ok, Task.t() | map()} | {:error, String.t()}

  @doc "Where a task the caller already knows about has got to."
  @callback get_task(address :: address(), task_id :: String.t()) ::
              {:ok, Task.t()} | {:error, String.t()}

  @doc "Asks the other agent to stop. It may already have finished."
  @callback cancel_task(address :: address(), task_id :: String.t()) ::
              {:ok, Task.t()} | {:error, String.t()}

  @doc "The other agent's card, which says what it will answer."
  @callback card(address :: address()) :: {:ok, Card.t()} | {:error, String.t()}

  @doc """
  Whether `address` is the shape this binding carries.

  Optional. `Lemieux.A2A` tries each binding it was given in order and the
  first to answer `true` carries the call, so a binding should claim only the
  shape it owns: a node is distribution's, a string beginning `http` is the
  JSON-RPC binding's. A binding that does not implement this is never chosen
  by shape and is used only when a caller names it with `:transport`.
  """
  @callback handles?(address :: address()) :: boolean()

  @callback card(address :: address(), opts :: keyword()) :: tuple()
  @callback get_task(address :: address(), task_id :: String.t(), opts :: keyword()) :: tuple()
  @callback cancel_task(address :: address(), task_id :: String.t(), opts :: keyword()) :: tuple()
  @callback list_tasks(address :: address(), params :: map(), opts :: keyword()) :: tuple()
  @callback subscribe(address :: address(), task_id :: String.t(), opts :: keyword()) :: tuple()
  @optional_callbacks handles?: 1,
                      card: 2,
                      get_task: 3,
                      cancel_task: 3,
                      list_tasks: 3,
                      subscribe: 3
end
