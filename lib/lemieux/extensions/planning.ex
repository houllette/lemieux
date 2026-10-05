defmodule Lemieux.Extensions.Planning do
  @moduledoc """
  Optional transcript-backed plans for one session.

  Tasks describe obligations, not scheduling authority. `completed` is the
  agent's report, not independent verification. Dependencies constrain declared
  readiness; assigning an owner grants no tools or permission. Reopening needs
  a reason, retained in history. The bounded plan is committed through the
  session's generic document seam before any successful tool result is returned.
  Hosts own cross-session work items and scheduling.

  ## Two ways to write it

  `set/2` replaces the whole list — titles and statuses, as the model sees the
  plan now — and needs no revision: it reads the current one itself and
  retries once if another write landed in between. It is the `todo` tool's
  `set` action and the ordinary way a model keeps a plan, because asking a
  model to `list` before every change, then echo a revision it just read,
  cost a round trip per update and was the step weaker models skipped. The
  fine-grained actions (`update/3` with `create`, `update`, `reopen`,
  `delete`) keep the compare-and-set on an observed revision for hosts and
  models that record dependencies, owners and evidence.

  ## What a host renders

  Every commit is a transcript entry, and a session broadcasts every entry,
  so a screen follows the plan by watching for

      {:lemieux, session_id, {:entry, %Lemieux.Entry{type: :extension_state,
        payload: %{"namespace" => "lemieux.plan", "revision" => revision,
                   "value" => plan}}}}

  and hydrates it from a resumed transcript the same way. `plan` is
  `%{"version" => 1, "next_id" => n, "tasks" => [task]}`; each task is
  `%{"id", "title", "status", "depends_on", "evidence", "owner"}` with status
  `pending`, `in_progress`, `completed` or `deleted`. `tasks/1` gives the
  visible list. The `todo` tool's result carries the same `revision` and
  `plan` as structured content.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Entry
  alias Lemieux.Extensions.Planning.Reducer
  alias Lemieux.Extensions.Planning.Tool
  alias Lemieux.Harness
  alias Lemieux.Session

  @namespace "lemieux.plan"

  @impl true
  def apply(harness, _opts) do
    harness
    |> Harness.update_tools(&(&1 ++ [Tool]))
    |> Harness.append_hooks(prepare_next_turn: &prepare/2)
  end

  @doc "Reads the plan independently of the model's compacted conversation."
  @spec read(session :: Session.session()) :: {:ok, map()} | {:error, term()}
  def read(session) do
    with {:ok, document} <- Session.document(session, @namespace) do
      value = document.value || %{"version" => 1, "next_id" => 1, "tasks" => []}

      if Reducer.valid?(value),
        do: {:ok, %{document | value: value}},
        else: {:error, :invalid_plan}
    end
  end

  @doc "Applies a pure plan mutation and durably commits against its observed revision."
  @spec update(session :: Session.session(), revision :: non_neg_integer(), command :: map()) ::
          {:ok, map()} | {:error, term()}
  def update(session, revision, command) do
    with {:ok, %{revision: current, value: plan}} <- read(session),
         :ok <- current_revision(current, revision),
         {:ok, next} <- Reducer.apply(plan, command) do
      if next == plan,
        do: {:ok, %{revision: current, value: plan}},
        else: Session.put_document(session, @namespace, revision, next)
    end
  end

  @doc """
  Replaces the whole plan with `tasks`, each `%{"title" => _, "status" => _}`
  and optionally the `"id"` of the task it restates.

  Reads the current revision itself and retries once on a conflict, since a
  whole-list write means "this is the plan now" whichever write it follows.
  """
  @spec set(session :: Session.session(), tasks :: [map()]) :: {:ok, map()} | {:error, term()}
  def set(session, tasks) when is_list(tasks), do: set(session, tasks, 2)

  defp set(session, tasks, attempts) do
    with {:ok, %{revision: revision, value: plan}} <- read(session),
         {:ok, next} <- Reducer.apply(plan, %{"action" => "set", "tasks" => tasks}) do
      commit_set(session, tasks, revision, plan, next, attempts)
    end
  end

  defp commit_set(_session, _tasks, revision, plan, plan, _attempts),
    do: {:ok, %{revision: revision, value: plan}}

  defp commit_set(session, tasks, revision, _plan, next, attempts) do
    case Session.put_document(session, @namespace, revision, next) do
      {:error, {:conflict, _current}} when attempts > 1 -> set(session, tasks, attempts - 1)
      committed -> committed
    end
  end

  @doc "The document namespace plan commits are recorded under."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The tasks a host shows: every task that is not deleted, in plan order, as
  `%{"id" => _, "title" => _, "status" => _}`.
  """
  @spec tasks(plan :: map() | nil) :: [%{required(String.t()) => String.t()}]
  def tasks(%{"tasks" => tasks}) when is_list(tasks) do
    for %{"status" => status} = task <- tasks, status != "deleted" do
      Map.take(task, ~w(id title status))
    end
  end

  def tasks(_plan), do: []

  @doc false
  @spec prepare(request :: Lemieux.Request.t(), context :: map()) :: term()
  def prepare(request, context) do
    case read(context.session) do
      {:ok, %{value: %{"tasks" => []}}} ->
        {:ok, request}

      {:ok, document} ->
        entry =
          Entry.new(:user, %{
            "text" =>
              "Current session plan (tracking data, not proof of completion):\n" <>
                summary(document)
          })

        {:ok, %{request | entries: request.entries ++ [entry]}}

      {:error, reason} ->
        {:deny, "cannot reconstruct session plan: #{inspect(reason)}"}
    end
  end

  @doc "A compact host/model view; complete state remains in the transcript."
  @spec summary(document :: map()) :: String.t()
  def summary(%{revision: revision, value: plan}) do
    lines =
      Enum.map(plan["tasks"], fn task ->
        "#{task["id"]} [#{task["status"]}] #{task["title"]}" <>
          if(task["depends_on"] == [],
            do: "",
            else: " (depends on #{Enum.join(task["depends_on"], ", ")})"
          )
      end)

    Enum.join(["Plan revision #{revision}" | lines], "\n")
  end

  defp current_revision(revision, revision), do: :ok
  defp current_revision(current, _expected), do: {:error, {:conflict, current}}
end
