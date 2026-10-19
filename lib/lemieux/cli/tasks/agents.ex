defmodule Lemieux.CLI.Tasks.Agents do
  @moduledoc "Host projection of agent assignments; observation never becomes a control capability."
  alias Lemieux.Background.Label
  alias Lemieux.Context
  alias Lemieux.Extensions.Watches.Record
  alias Lemieux.ID.Shorthand
  alias Lemieux.Session
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Result
  alias Lemieux.Writers
  alias Lemieux.Writers.Artifact

  @doc false
  @spec rows(parent :: pid()) :: [map()]
  def rows(parent) do
    context = Session.work_context(parent, ["lemieux.writers."])
    live = live_children(parent)

    results =
      Map.new(
        Enum.filter(context.entries, &(&1.type == :subagent_result)),
        &{&1.payload["child_id"], &1}
      )

    delegates =
      context.entries
      |> Enum.filter(&(&1.type == :subagent_spawn))
      |> Enum.take(-128)
      |> Enum.map(
        &delegate(&1, results[&1.payload["child_id"]], live[&1.payload["child_id"]], context)
      )

    delegates ++ writer_rows(context)
  end

  @doc false
  @spec detail(parent :: pid(), row :: map()) :: map()
  def detail(parent, %{agent_type: :delegate} = row) do
    case reference(parent, row.agent_id) do
      {:ok, ref} ->
        case Subagent.inspect(ref) do
          {:ok, snapshot} ->
            Map.put(row, :logs, trace(snapshot))

          {:error, reason} ->
            Map.put(row, :logs, "Agent inspection unavailable: #{inspect(reason)}")
        end

      _settled ->
        Map.put(row, :logs, row.result_text || "The original agent is no longer running.")
    end
  end

  def detail(parent, %{agent_type: :writer, group_id: id} = row) do
    with {:ok, %{id: ^id} = ref} <- Writers.current(parent),
         {:ok, view} <- Writers.snapshot(ref),
         writer when not is_nil(writer) <-
           Enum.find(view.writers, &(&1.transcript_id == row.agent_id)) do
      Map.put(row, :logs, writer_output(writer))
    else
      _gone -> Map.put(row, :logs, row.result_text || "No result yet.")
    end
  end

  defp writer_output(%{artifact: %Artifact{} = artifact}) do
    with {:ok, report} <- File.read(artifact.report_path),
         true <- Artifact.hash(report) == artifact.report_sha256 do
      report |> readable_answer() |> Record.text(32_000)
    else
      _unavailable -> "The original report is unavailable or its digest no longer matches."
    end
  end

  defp writer_output(%{session: session}) when is_pid(session),
    do: trace(%{session: Session.snapshot(session)})

  defp writer_output(_writer), do: "Waiting for agent activity…"

  @doc false
  @spec cancel(parent :: pid(), row :: map()) :: :ok | {:error, term()}
  def cancel(parent, %{agent_type: :delegate, agent_id: id}) do
    with {:ok, ref} <- reference(parent, id), do: Subagent.cancel(ref, :cancelled_from_tasks)
  end

  def cancel(parent, %{agent_type: :writer, group_id: id}) do
    case Writers.current(parent) do
      {:ok, %{id: ^id}} -> Writers.cancel_current(parent)
      {:ok, _other_batch} -> {:error, :not_running}
      error -> error
    end
  end

  @doc false
  @spec steer(parent :: pid(), row :: map(), instruction :: String.t()) :: :ok | {:error, term()}
  def steer(parent, %{agent_type: :delegate, agent_id: id}, instruction) do
    with {:ok, ref} <- reference(parent, id), do: Subagent.steer(ref, instruction)
  end

  def steer(_parent, _row, _instruction), do: {:error, :steering_unavailable}

  defp references(parent) do
    case Subagent.current(parent) do
      {:ok, groups} -> Enum.flat_map(groups, &group_children/1)
      _gone -> []
    end
  end

  defp group_children(group) do
    case Subagent.children(group) do
      {:ok, refs} -> refs
      _denied -> []
    end
  end

  defp reference(parent, id) do
    case Enum.find(references(parent), &(&1.id == id)) do
      nil -> {:error, :not_running}
      ref -> {:ok, ref}
    end
  end

  defp live_children(parent) do
    Map.new(references(parent), fn ref ->
      value =
        case Subagent.inspect(ref, include_entries: false) do
          {:ok, snapshot} -> snapshot
          _denied -> nil
        end

      {ref.id, value}
    end)
  end

  defp delegate(spawn, result, live, context) do
    payload = spawn.payload
    task = payload["task"] || %{}

    status =
      cond do
        live -> Atom.to_string(live.status)
        result -> result.payload["status"]
        Map.has_key?(context.owners, payload["group_id"]) -> "restricted"
        true -> "unavailable"
      end

    row =
      base(
        payload["child_id"],
        task["objective"],
        status,
        spawn.at,
        result && result.at,
        context.id
      )

    Map.merge(row, %{
      agent_type: :delegate,
      group_id: payload["group_id"],
      role: payload["definition_id"],
      instructions: brief(task),
      statistics: statistics(live),
      result_text: if(result, do: result_text(result.payload)),
      steerable?: row.running?,
      cancel_label: "Cancel agent",
      active?: row.active? or status == "restricted"
    })
  end

  defp writer_rows(context) do
    context.entries
    |> Enum.filter(&(&1.type == :extension_state))
    |> Enum.group_by(& &1.payload["namespace"])
    |> Enum.flat_map(fn {_namespace, entries} ->
      entry = List.last(entries)
      value = entry.payload["value"]

      Enum.map(
        value["writers"] || [],
        &writer(&1, value["id"], hd(entries).at, entry.at, context.id)
      )
    end)
  end

  defp writer(writer, group_id, started, updated, parent_id) do
    agent_id = writer["transcript_id"] || "#{group_id}:#{writer["id"]}"
    finished = if writer["status"] not in ~w(starting running), do: updated

    row =
      base(
        agent_id,
        writer["task"] || "Write approved workspace paths",
        writer["status"],
        started,
        finished,
        parent_id
      )

    Map.merge(row, %{
      id: "writer:#{group_id}:#{writer["id"]}",
      name: Shorthand.of("#{group_id}:#{writer["id"]}"),
      agent_type: :writer,
      group_id: group_id,
      role: "Isolated writer",
      instructions:
        "#{writer["task"]}\n\nOwned paths:\n#{Enum.join(writer["paths"] || [], "\n")}",
      result_text: writer_result(writer),
      statistics: nil,
      steerable?: false,
      cancel_label: "Cancel writer batch"
    })
  end

  defp writer_result(%{"artifact" => artifact}) when is_map(artifact) do
    "Reviewable patch ready.\nManifest: #{artifact["manifest_path"]}"
  end

  defp writer_result(%{"error" => error}) when is_binary(error), do: error
  defp writer_result(_writer), do: nil

  defp base(id, objective, status, started, finished, parent_id) do
    status = normalize_status(status)
    running? = status in ~w(queued starting running cancelling)
    started = timestamp(started)
    finished = timestamp(finished)

    %{
      id: "agent:" <> id,
      agent_id: id,
      kind: :agent,
      type_label: "Agent",
      parent_id: nil,
      owner_id: parent_id,
      owner_label: nil,
      managed?: false,
      task_id: nil,
      watch_id: nil,
      label: Label.summary(objective),
      description: Label.summary(objective),
      name: Shorthand.of(id),
      source: "agent",
      status: status,
      status_label: Record.status_name(status),
      running?: running?,
      watching?: false,
      active?: running?,
      observation: nil,
      delivered?: not running?,
      follow_up?: false,
      target: %{},
      deadline: nil,
      summary: nil,
      url: nil,
      bytes: 0,
      command: nil,
      tracking_label: nil,
      history: [],
      started_at: started,
      finished_at: finished,
      sort_time: finished || started || "",
      elapsed: elapsed(started, finished)
    }
  end

  defp normalize_status(status) when status in ~w(ok completed ready integrated), do: "success"
  defp normalize_status("timeout"), do: "timed_out"
  defp normalize_status("budget_exhausted"), do: "budget exhausted"
  defp normalize_status(status), do: status || "unavailable"
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value), do: value

  defp elapsed(started, finished) do
    with {:ok, from, _} <- DateTime.from_iso8601(started),
         {:ok, to, _} <-
           DateTime.from_iso8601(finished || DateTime.to_iso8601(DateTime.utc_now())) do
      seconds = max(DateTime.diff(to, from), 0)
      if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    else
      _ -> ""
    end
  end

  defp brief(task) do
    [
      task["objective"]
      | Enum.map(~w(non_goals expected_evidence acceptance_criteria), fn key ->
          case task[key] do
            [_ | _] = values ->
              "#{String.replace(key, "_", " ")}:\n" <> Enum.map_join(values, "\n", &"• #{&1}")

            _ ->
              nil
          end
        end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp statistics(%{session: %{context: context}}) do
    "#{Context.abbreviate(Context.cumulative(context))} tokens used · #{Context.abbreviate(context.tokens)} context"
  end

  defp statistics(_snapshot), do: nil

  defp result_text(payload) do
    case Result.from_map(payload) do
      {:ok, result} -> result.answer
      _invalid -> "Result unavailable"
    end
  end

  defp trace(%{result: %Result{} = result}), do: result.answer

  defp trace(%{session: %{entries: entries}}) do
    entries |> Enum.take(-24) |> Enum.map_join("\n\n", &entry_text/1) |> Record.text(32_000)
  end

  defp trace(_snapshot), do: "Waiting for agent activity…"

  defp entry_text(%{type: :tool_result, payload: payload}),
    do: "#{payload["name"]}\n#{payload["output"]}"

  defp entry_text(%{type: :assistant, payload: payload}) do
    (payload["content"] || [])
    |> Enum.map_join("", &Map.get(&1, "text", ""))
    |> readable_answer()
  end

  defp entry_text(_entry), do: ""

  defp readable_answer(text) do
    case JSON.decode(text) do
      {:ok, %{"report" => %{"summary" => _} = report}} ->
        report_text(report)

      {:ok, %{"answer" => answer}} when is_binary(answer) ->
        answer

      {:ok, %{"summary" => summary} = report} when is_binary(summary) ->
        report_text(report)

      _other ->
        text
    end
  end

  defp report_text(report) do
    [
      report["summary"]
      | Enum.flat_map(~w(critical_findings uncertainties), &report_section(report, &1))
    ]
    |> Enum.join("\n\n")
  end

  defp report_section(report, key) do
    case report[key] do
      [_ | _] = values ->
        [
          "#{String.replace(key, "_", " ")}:\n" <>
            Enum.map_join(values, "\n", &("• " <> finding_text(&1)))
        ]

      _empty ->
        []
    end
  end

  defp finding_text(value) when is_binary(value), do: value
  defp finding_text(value), do: JSON.encode!(value)
end
