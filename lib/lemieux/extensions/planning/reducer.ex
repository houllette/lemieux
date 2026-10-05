defmodule Lemieux.Extensions.Planning.Reducer do
  @moduledoc false
  import Kernel, except: [apply: 2]

  @statuses ~w(pending in_progress completed deleted)

  @spec valid?(plan :: term()) :: boolean()
  def valid?(%{"version" => 1, "tasks" => tasks, "next_id" => next})
      when is_list(tasks) and length(tasks) <= 64 and is_integer(next) and next > 0 do
    Enum.all?(tasks, &valid_task?/1) and
      length(Enum.uniq_by(tasks, & &1["id"])) == length(tasks) and valid_graph?(tasks)
  end

  def valid?(_plan), do: false

  @spec apply(plan :: map(), command :: map()) :: {:ok, map()} | {:error, term()}
  def apply(plan, %{"action" => "create", "title" => title} = command) do
    task = %{
      "id" => "t#{plan["next_id"]}",
      "title" => title,
      "status" => "pending",
      "depends_on" => Map.get(command, "depends_on", []),
      "evidence" => [],
      "owner" => Map.get(command, "owner")
    }

    validate(%{plan | "next_id" => plan["next_id"] + 1, "tasks" => plan["tasks"] ++ [task]})
  end

  # The whole plan at once, as the model currently sees it. Items keep the id
  # they already had — named explicitly, or matched by title — so a host
  # watching the plan sees the same task move rather than one task deleted
  # and another created, and dependencies and evidence recorded through the
  # fine-grained actions survive a `set` that restates them. A task the new
  # list leaves out is gone; its history is the earlier revisions.
  def apply(plan, %{"action" => "set", "tasks" => items}) when is_list(items) do
    live = Enum.reject(plan["tasks"], &(&1["status"] == "deleted"))

    with {:ok, tasks, next_id} <- set_tasks(items, live, plan["next_id"]) do
      validate(%{plan | "tasks" => settle_dependencies(tasks), "next_id" => next_id})
    end
  end

  def apply(plan, %{"action" => action, "id" => id} = command)
      when action in ~w(update reopen delete) do
    case Enum.find(plan["tasks"], &(&1["id"] == id)) do
      nil -> {:error, :unknown_task}
      task -> change(plan, task, action, command)
    end
  end

  def apply(_plan, _command), do: {:error, :invalid_plan_command}

  @set_statuses ~w(pending in_progress completed)

  defp set_tasks(items, live, next_id) do
    by_id = Map.new(live, &{&1["id"], &1})
    by_title = live |> Enum.reverse() |> Map.new(&{&1["title"], &1})

    items
    |> Enum.reduce_while({:ok, [], next_id, MapSet.new()}, fn item, {:ok, tasks, next, used} ->
      case set_task(item, by_id, by_title, next, used) do
        {:ok, task, next} -> {:cont, {:ok, [task | tasks], next, MapSet.put(used, task["id"])}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tasks, next, _used} -> {:ok, Enum.reverse(tasks), next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_task(%{"title" => title, "status" => status} = item, by_id, by_title, next, used)
       when status in @set_statuses do
    existing =
      case Map.get(item, "id") do
        nil -> by_title[title]
        id -> by_id[id] || {:unknown, id}
      end

    case existing do
      {:unknown, _id} ->
        {:error, :unknown_task}

      %{"id" => id} = task ->
        if MapSet.member?(used, id),
          do: fresh(title, status, next),
          else: {:ok, restated(task, title, status), next}

      nil ->
        fresh(title, status, next)
    end
  end

  defp set_task(_item, _by_id, _by_title, _next, _used), do: {:error, :invalid_plan_command}

  defp fresh(title, status, next) do
    {:ok,
     %{
       "id" => "t#{next}",
       "title" => title,
       "status" => status,
       "depends_on" => [],
       "evidence" => [],
       "owner" => nil
     }, next + 1}
  end

  # A task restated as no longer completed has been reopened by the model's
  # own report; its evidence belonged to the completion it no longer claims.
  defp restated(task, title, status) do
    evidence = if status == "completed", do: task["evidence"], else: []

    task
    |> Map.merge(%{"title" => title, "status" => status, "evidence" => evidence})
    |> Map.delete("reopened_reason")
  end

  # Dependencies recorded through `create`/`update` are kept while they still
  # make sense: a dependency the new list dropped is forgotten, and a task the
  # model reports in progress or done has its unmet dependencies released —
  # the report is the model's, and refusing the whole list over a stale edge
  # would leave the host showing a plan the model has moved past.
  defp settle_dependencies(tasks) do
    present = Map.new(tasks, &{&1["id"], &1["status"]})

    Enum.map(tasks, fn task ->
      depends_on = Enum.filter(task["depends_on"], &Map.has_key?(present, &1))

      depends_on =
        if task["status"] in ~w(in_progress completed) and
             Enum.any?(depends_on, &(present[&1] != "completed")),
           do: [],
           else: depends_on

      %{task | "depends_on" => depends_on}
    end)
  end

  defp change(_plan, %{"status" => "deleted"}, _action, _command), do: {:error, :deleted_task}

  defp change(plan, task, "reopen", %{"reason" => reason}) do
    if task["status"] == "completed" and text?(reason, 1000),
      do:
        replace(
          plan,
          Map.merge(task, %{"status" => "pending", "reopened_reason" => reason, "evidence" => []})
        ),
      else: {:error, :reopen_needs_completed_task_and_reason}
  end

  defp change(plan, task, "delete", _command),
    do: replace(plan, Map.put(task, "status", "deleted"))

  defp change(plan, task, "update", command) do
    fields = Map.take(command, ~w(title status depends_on evidence owner))
    next = Map.merge(task, fields)

    cond do
      fields == %{} -> {:error, :empty_update}
      task["status"] == "completed" and next != task -> {:error, :reopen_required}
      next["status"] == "deleted" -> {:error, :use_delete}
      true -> replace(plan, next)
    end
  end

  defp change(_plan, _task, _action, _command), do: {:error, :invalid_plan_command}

  defp replace(plan, next),
    do:
      validate(%{
        plan
        | "tasks" =>
            Enum.map(plan["tasks"], fn task ->
              if task["id"] == next["id"], do: next, else: task
            end)
      })

  defp validate(plan) do
    if valid?(plan), do: {:ok, plan}, else: {:error, :invalid_plan_or_dependencies}
  end

  defp valid_task?(%{
         "id" => id,
         "title" => title,
         "status" => status,
         "depends_on" => deps,
         "evidence" => refs,
         "owner" => owner
       }) do
    text?(id, 64) and text?(title, 300) and status in @statuses and refs?(deps, 64) and
      refs?(refs, 16) and (is_nil(owner) or text?(owner, 120))
  end

  defp valid_task?(_task), do: false

  defp refs?(refs, max) when is_list(refs) and length(refs) <= max,
    do: Enum.all?(refs, &text?(&1, 1000)) and length(refs) == length(Enum.uniq(refs))

  defp refs?(_refs, _max), do: false

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) <= max and String.trim(value) != ""

  defp text?(_value, _max), do: false

  defp valid_graph?(tasks) do
    by_id = Map.new(tasks, &{&1["id"], &1})

    Enum.all?(tasks, fn task ->
      Enum.all?(task["depends_on"], &valid_dependency?(by_id[&1], task)) and
        not cycle?(task["id"], by_id)
    end)
  end

  defp valid_dependency?(nil, _task), do: false
  defp valid_dependency?(%{"status" => "deleted"}, _task), do: false

  defp valid_dependency?(dependency, %{"status" => status})
       when status in ~w(in_progress completed),
       do: dependency["status"] == "completed"

  defp valid_dependency?(_dependency, _task), do: true

  defp cycle?(id, tasks), do: reaches?(tasks[id]["depends_on"], id, tasks, %{})

  defp reaches?([], _target, _tasks, _seen), do: false
  defp reaches?([target | _rest], target, _tasks, _seen), do: true

  defp reaches?([id | rest], target, tasks, seen) do
    if Map.has_key?(seen, id),
      do: reaches?(rest, target, tasks, seen),
      else:
        reaches?(
          (get_in(tasks, [id, "depends_on"]) || []) ++ rest,
          target,
          tasks,
          Map.put(seen, id, true)
        )
  end
end
