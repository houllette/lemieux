defmodule Lemieux.CLI.Tasks do
  @moduledoc """
  Human control of the current session's background commands and external watches.

  Reads and actions run outside the drawing process. Every action resolves its
  target again from the owning session; an old row or another session's task
  identifier grants no authority. Cancelling a command first revokes its pending
  continuation. External sources expose observation controls only.
  """
  alias Lemieux.Background
  alias Lemieux.CLI.Tasks.Activity
  alias Lemieux.CLI.Watches, as: Host
  alias Lemieux.Extensions.Watches
  alias Lemieux.Extensions.Watches.Record
  alias Lemieux.ID.Shorthand
  alias Lemieux.Session

  @doc "Reads bounded metadata plus the selected task's logs, without inference."
  @spec snapshot(session :: pid(), selected :: String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def snapshot(session, selected \\ nil) do
    with {:ok, info} <- runtime_info(session), do: snapshot_info(info, selected)
  catch
    :exit, _reason -> {:error, :session_disconnected}
  end

  defp snapshot_info(info, selected) do
    manager = manager(info)
    watches = if manager, do: Watches.list(manager), else: []
    tasks = Background.list_tree(info.supervisor, info.id) ++ writer_tasks(info)
    rows = rows(tasks, watches)
    rows = Enum.map(rows, &scope(&1, tasks, info))
    selected = Enum.find(rows, &(&1.id == selected)) || List.first(rows)

    {:ok,
     %{
       rows: rows,
       selected: selected && selected.id,
       detail: detail(selected, info, watches),
       sources: if(manager, do: Watches.sources(manager) -- ["background"], else: []),
       monitoring?: not is_nil(manager),
       auto_continue?: not is_nil(manager) and Watches.defaults(manager).follow_up
     }}
  end

  @doc "Applies a human action to a currently owned row without a model request."
  @spec action(session :: pid(), id :: String.t(), action :: atom()) :: :ok | {:error, term()}
  def action(session, id, action) do
    with {:ok, info} <- runtime_info(session),
         {:ok, view} <- snapshot_info(info, id),
         %{id: ^id} = row <- Enum.find(view.rows, &(&1.id == id)) do
      owner = %{info | id: row.owner_id}
      perform(action, row, owner, manager(owner))
    else
      nil -> {:error, :task_unavailable}
      error -> error
    end
  catch
    :exit, _reason -> {:error, :session_disconnected}
  end

  @doc "Registers an existing external run from a native form; never starts external work."
  @spec add(session :: pid(), source :: String.t(), fields :: map(), follow_up? :: boolean()) ::
          :ok | {:error, term()}
  def add(session, source, fields, follow_up?) do
    with {:ok, info} <- runtime_info(session),
         manager when not is_nil(manager) <- manager(info),
         {minutes, ""} when minutes in 1..43_200 <- Integer.parse(fields["minutes"] || "60"),
         {:ok, _watch} <-
           Watches.register(manager, source, Map.drop(fields, ["minutes"]),
             timeout_ms: minutes * 60_000,
             follow_up: follow_up?,
             continuation_origin: "user"
           ) do
      :ok
    else
      nil -> {:error, :monitoring_unavailable}
      :error -> {:error, :invalid_deadline}
      {number, _rest} when is_integer(number) -> {:error, :invalid_deadline}
      error -> error
    end
  catch
    :exit, _reason -> {:error, :session_disconnected}
  end

  defp runtime_info(session) do
    case Session.info(session) do
      %{supervisor: supervisor, id: id} = info
      when is_atom(supervisor) and not is_nil(supervisor) and is_binary(id) ->
        {:ok, info}

      _info ->
        {:error, :native_tasks_unavailable}
    end
  end

  defp manager(info) do
    case Host.resolve(%{supervisor: info.supervisor, session_id: info.id}) do
      {:ok, manager} -> manager
      {:error, _reason} -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp writer_tasks(info) do
    with {:ok, parent} <- Lemieux.session(info.supervisor, info.id),
         {:ok, ref} <- Lemieux.Writers.current(parent),
         {:ok, view} <- Lemieux.Writers.snapshot(ref) do
      Enum.flat_map(view.writers, &writer_commands(&1, info.supervisor))
    else
      _unavailable -> []
    end
  catch
    :exit, _gone -> []
  end

  defp writer_commands(%{transcript_id: id} = writer, supervisor) when is_binary(id),
    do:
      Enum.map(
        Background.list(supervisor, id),
        &Map.put(&1, :owner_label, "Writer #{writer.id}")
      )

  defp writer_commands(_writer, _supervisor), do: []

  defp scope(row, tasks, info) do
    task = Enum.find(tasks, &(&1.id == row.task_id))
    owner = if task, do: task.session_id, else: info.id

    owner_label =
      if owner != info.id, do: Map.get(task, :owner_label, "Delegate #{Shorthand.of(owner)}")

    row = Map.merge(row, %{owner_id: owner, owner_label: owner_label, managed?: owner != info.id})

    if row.managed?,
      do: %{
        row
        | label: "#{owner_label} · #{row.label}",
          observation: "managed by agent",
          follow_up?: true
      },
      else: row
  end

  defp rows(tasks, watches) do
    groups = Activity.group(watches)

    commands =
      Enum.map(tasks, fn task ->
        group =
          Enum.find(
            groups,
            &(&1.watch["source"] == "background" and &1.watch["target"]["task_id"] == task.id)
          )

        activity_row(group, task)
      end)

    ids = MapSet.new(tasks, & &1.id)

    external =
      groups
      |> Enum.reject(
        &(&1.watch["source"] == "background" and
            MapSet.member?(ids, &1.watch["target"]["task_id"]))
      )
      |> Enum.map(&activity_row(&1, nil))

    Enum.sort_by(commands ++ external, &{&1.active?, &1.sort_time, &1.id}, :desc)
  end

  defp activity_row(nil, task), do: Activity.decorate(row(nil, task), task, [])

  defp activity_row(group, task),
    do: Activity.decorate(row(group.watch, task), task, group.history)

  defp row(watch, nil), do: watch_row(watch)

  defp row(watch, task) do
    Map.merge(watch_row(watch), %{
      id: "task:" <> task.id,
      task_id: task.id,
      label: task.command,
      command: task.command,
      name: task.name,
      description: task.description,
      target: %{"task_id" => task.id},
      status: task_status(task),
      summary: if(task.status == :cancelled, do: nil, else: watch_row(watch).summary),
      running?: task.status == :running,
      bytes: task.output_bytes
    })
  end

  defp watch_row(nil),
    do: %{
      id: nil,
      task_id: nil,
      watch_id: nil,
      label: "",
      source: "background",
      status: "",
      running?: false,
      watching?: false,
      observation: nil,
      follow_up?: false,
      delivered?: false,
      target: %{},
      deadline: nil,
      summary: nil,
      url: nil,
      bytes: 0
    }

  defp watch_row(watch) do
    result = watch["result"] || %{}

    row = %{
      id: Activity.id(watch),
      task_id: nil,
      watch_id: watch["id"],
      label: label(watch["source"], watch["target"]),
      source: watch["source"],
      status: outcome(result["outcome"], watch["status"]),
      running?: false,
      watching?: watch["status"] == "watching",
      observation: watch["status"],
      follow_up?: watch["follow_up"],
      delivered?: watch["delivery"] == "delivered",
      target: watch["target"],
      deadline: watch["deadline_at"],
      summary: result["summary"] || watch["last_status"],
      url: result["url"],
      bytes: result["logs_bytes"] || 0
    }

    if watch["source"] == "background",
      do:
        Map.merge(row, %{
          name: Record.task_name(watch),
          description: Record.card(watch)["summary"],
          label: Record.task_name(watch)
        }),
      else: row
  end

  defp outcome(value, fallback) when value in [nil, ""], do: fallback
  defp outcome(value, _fallback), do: value

  defp label("github", target), do: "#{target["repository"]} · run #{target["run_id"]}"
  defp label(source, target), do: "#{source} · #{target["run_id"] || target["task_id"]}"
  defp task_status(%{status: :exited, exit_status: 0}), do: "success"
  defp task_status(%{status: :exited, exit_status: status}), do: "failed · exit #{status}"
  defp task_status(task), do: Atom.to_string(task.status)

  # A prefix preview freezes as soon as a chatty task reaches the cap. Keep
  # the newest bytes so following logs continues to show actual progress.
  defp log_tail(output) when byte_size(output) <= 32_000, do: Record.text(output, 32_000)

  defp log_tail(output) do
    if String.valid?(output) do
      tail = binary_part(output, byte_size(output) - 32_000, 32_000)
      "[Showing the latest 32 KB of retained output]\n" <> valid_tail(tail)
    else
      "(invalid UTF-8 output)"
    end
  end

  defp valid_tail(tail) do
    if String.valid?(tail), do: tail, else: valid_tail(binary_part(tail, 1, byte_size(tail) - 1))
  end

  defp detail(nil, _info, _watches), do: nil

  defp detail(%{task_id: id} = row, info, _watches) when is_binary(id) do
    case Background.poll(info.supervisor, row.owner_id, id) do
      {:ok, task} ->
        Map.put(row, :logs, log_tail(task.output))

      {:error, _reason} ->
        Map.put(row, :logs, "Original command is unavailable; it was not restarted.")
    end
  end

  defp detail(row, _info, watches) do
    watch = Enum.find(watches, &(&1["id"] == row.watch_id))
    Map.put(row, :logs, Record.text(get_in(watch, ["result", "logs"]), 8000))
  end

  defp perform(action, %{managed?: true}, _info, _manager)
       when action in [:stop, :watch, :follow_up, :clear],
       do: {:error, :managed_task}

  defp perform(:cancel, %{task_id: id} = row, info, manager) when is_binary(id) do
    with :ok <- stop_watch(manager, row.watch_id),
         do: Background.cancel(info.supervisor, info.id, id)
  end

  defp perform(:cancel, _row, _info, _manager), do: {:error, :external_job_cannot_be_cancelled}
  defp perform(:stop, row, _info, manager), do: stop_watch(manager, row.watch_id)

  defp perform(:watch, %{source: "background", running?: false}, _info, manager)
       when not is_nil(manager),
       do: {:error, :already_finished}

  defp perform(:watch, row, _info, manager) when not is_nil(manager),
    do:
      normalize(
        Watches.register(manager, row.source, row.target,
          reuse: false,
          label: row.label,
          continuation_origin: "user"
        )
      )

  defp perform(:follow_up, row, _info, manager) when not is_nil(manager),
    do: normalize(Watches.follow_up(manager, row.watch_id, not row.follow_up?))

  defp perform(:clear, %{running?: true}, _info, _manager), do: {:error, :running}

  defp perform(:clear, row, info, manager) do
    with :ok <- clear_watch(manager, row.watch_id), do: clear_task(row.task_id, info)
  end

  defp perform(_action, _row, _info, _manager), do: {:error, :monitoring_unavailable}

  defp stop_watch(_manager, nil), do: :ok
  defp stop_watch(nil, _id), do: {:error, :monitoring_unavailable}
  defp stop_watch(manager, id), do: normalize(Watches.stop(manager, id))
  defp clear_watch(_manager, nil), do: :ok
  defp clear_watch(nil, _id), do: {:error, :monitoring_unavailable}
  defp clear_watch(manager, id), do: normalize(Watches.forget(manager, id))
  defp clear_task(nil, _info), do: :ok
  defp clear_task(id, info), do: Background.clear_output(info.supervisor, info.id, id)
  defp normalize({:ok, _value}), do: :ok
  defp normalize(error), do: error
end
