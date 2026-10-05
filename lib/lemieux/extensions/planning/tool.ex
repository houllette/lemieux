defmodule Lemieux.Extensions.Planning.Tool do
  @moduledoc """
  The optional `todo` tool.

  `set` restates the whole list and needs no revision; the fine-grained
  actions commit against the revision `list` returned. See
  `Lemieux.Extensions.Planning` for why both exist.

  Parallel-safe, and serialized only against other `todo` calls: the plan is
  session state rather than a file, so a plan update may share a wave with
  reads and commands, while two plan writes in one wave take turns on the
  `lemieux.plan` resource instead of racing each other's revision.
  """
  @behaviour Lemieux.Tool

  alias Lemieux.Extensions.Planning
  alias Lemieux.Tool.Result

  @impl true
  def name, do: "todo"

  @impl true
  def description,
    do:
      "Keep a plan for multi-step work. Send the whole list with action `set` whenever it " <>
        "changes — each task a title and a status (pending, in_progress, completed) — and " <>
        "keep the task you are working on in_progress. `list` shows the plan. Completed means " <>
        "you report it done, not that anything verified it. The create, update, reopen and " <>
        "delete actions edit single tasks and need the revision `list` returned."

  @impl true
  def parallel_safe?, do: true

  @impl true
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(set list create update reopen delete)},
        "tasks" => %{
          "type" => "array",
          "description" => "For set: the complete plan, in order.",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["title", "status"],
            "properties" => %{
              "title" => %{"type" => "string"},
              "status" => %{"type" => "string", "enum" => ~w(pending in_progress completed)},
              "id" => %{"type" => "string", "description" => "Keep an existing task's id."}
            }
          }
        },
        "revision" => %{"type" => "integer", "minimum" => 0},
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "reason" => %{"type" => "string"},
        "owner" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ~w(pending in_progress completed)},
        "depends_on" => %{"type" => "array", "items" => %{"type" => "string"}},
        "evidence" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }
  end

  # Session state only: nothing outside the transcript changes, so no host
  # approval policy has anything to ask about.
  @impl true
  def metadata,
    do: %{
      effects: %{class: "write", resource_types: ["session_plan"]},
      policy: %{approval: "never"},
      runtime: %{concurrency: %{class: "resource", resource_key: Planning.namespace()}}
    }

  @impl true
  def run(%{"action" => "list"}, context), do: result(Planning.read(context.session))

  def run(%{"action" => "set", "tasks" => tasks}, context) when is_list(tasks),
    do: result(Planning.set(context.session, tasks))

  def run(%{"action" => "set"}, _context),
    do: {:error, "set needs tasks: the complete plan as a list of titles and statuses"}

  def run(%{"revision" => revision} = command, context)
      when is_integer(revision) and revision >= 0,
      do: result(Planning.update(context.session, revision, command))

  def run(_args, _context),
    do:
      {:error,
       "use set with the whole list, or give the revision from list for a single-task change"}

  defp result({:ok, document}),
    do:
      {:ok,
       Result.new(Planning.summary(document),
         structured_content: %{
           "revision" => document.revision,
           "plan" => document.value
         }
       )}

  defp result({:error, reason}), do: {:error, "plan unchanged: #{inspect(reason)}"}
end
