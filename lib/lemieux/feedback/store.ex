defmodule Lemieux.Feedback.Store do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Persistence contract for feedback revisions.

  This store is intentionally separate from `Lemieux.Store`. Transcript
  entries are provider context and affect resume/replay; feedback is evidence
  about a run and must never be replayed to the model merely because it was
  captured. Hosts can implement this behavior over their tenant-aware store.
  """

  alias Lemieux.Feedback

  @type t :: {module(), state :: term()}
  @type feedback_id :: String.t()

  @callback append(state :: term(), feedback :: Feedback.t()) :: :ok | {:error, term()}
  @callback read(state :: term(), feedback_id :: feedback_id()) ::
              {:ok, [Feedback.t()]} | {:error, term()}
  @callback list_feedback(state :: term()) :: {:ok, [feedback_id()]} | {:error, term()}

  @doc "Appends one immutable revision."
  @spec append(store :: t(), feedback :: Feedback.t()) :: :ok | {:error, term()}
  def append({module, state}, %Feedback{} = feedback), do: module.append(state, feedback)

  @doc "Reads every revision in append order."
  @spec read(store :: t(), feedback_id :: feedback_id()) ::
          {:ok, [Feedback.t()]} | {:error, term()}
  def read({module, state}, id), do: module.read(state, id)

  @doc "Reads the newest revision."
  @spec latest(store :: t(), feedback_id :: feedback_id()) ::
          {:ok, Feedback.t()} | {:error, term()}
  def latest(store, id) do
    with {:ok, revisions} <- read(store, id),
         %Feedback{} = latest <- List.last(revisions) do
      {:ok, latest}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Lists feedback ids in lexical creation order."
  @spec list_feedback(store :: t()) :: {:ok, [feedback_id()]} | {:error, term()}
  def list_feedback({module, state}), do: module.list_feedback(state)
end
