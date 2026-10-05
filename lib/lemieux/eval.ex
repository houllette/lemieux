defmodule Lemieux.Eval do
  @moduledoc """
  Where a session's `elixir` tool evaluates, for a host holding the session.

  `Lemieux.Eval.Sandbox` is the node itself, addressed the way a tool
  addresses it: by the runtime it is mounted in and the session id. A front
  end offering `/attach` has neither — it has a pid — so these three
  functions ask the session for its runtime and go on from there.

  They used to be on `Lemieux.Session`, for exactly that reason: the session
  was the one thing that knew which runtime it belonged to. That put a
  dependency on this opt-in tool inside the core loop, and every embedder
  without the tool carried it. The session now names its runtime in
  `Lemieux.Session.snapshot/1`, which is a fact about the session rather than
  an opinion about evaluation nodes, and this module is the only place that
  turns the fact into a sandbox address.

  Attaching remains a person's decision, and remains dangerous:
  `Lemieux.Eval.Attach` says why.
  """

  alias Lemieux.Eval.Sandbox
  alias Lemieux.Session

  @doc """
  Points the session's `elixir` tool at a node somebody else is running.

  Synchronous, and blocking: connecting and injecting take a moment, and it is
  a person's command either way, so there is somebody waiting for the answer.
  """
  @spec attach(session :: GenServer.server(), target :: String.t()) ::
          {:ok, node()} | {:error, String.t()}
  def attach(session, target), do: Sandbox.attach(context(session), target)

  @doc "Goes back to evaluating on the node lemieux started for this session."
  @spec detach(session :: GenServer.server()) :: :ok | {:error, String.t()}
  def detach(session), do: Sandbox.detach(context(session))

  @doc "The node the session's `elixir` tool is evaluating on, or `nil` for its own."
  @spec attached(session :: GenServer.server()) :: node() | nil
  def attached(session), do: Sandbox.target(context(session))

  # The same shape a tool is given, minus the call it is not part of.
  defp context(session) do
    %{id: id, supervisor: supervisor} = Session.snapshot(session)
    %{session_id: id, supervisor: supervisor}
  end
end
