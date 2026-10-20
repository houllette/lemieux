defmodule Lemieux.CLI.Tasks.Activity do
  @moduledoc false
  alias Lemieux.Extensions.Watches.Record

  # Observation attempts are evidence about one activity, not additional tasks.
  # Their stable identity also keeps selection intact after pause/resume.
  @spec group(watches :: [map()]) :: [%{watch: map(), history: [map()]}]
  def group(watches) do
    watches
    |> Enum.group_by(&{&1["source"], &1["target"]})
    |> Enum.map(fn {_target, observations} ->
      history =
        Enum.sort_by(observations, &{&1["created_order"] || &1["created_at"], &1["id"]}, :desc)

      %{watch: hd(history), history: history}
    end)
  end

  @spec id(watch :: map()) :: String.t()
  def id(%{"source" => "background", "target" => %{"task_id" => id}}), do: "task:" <> id

  def id(watch) do
    identity = :erlang.term_to_binary({watch["source"], watch["target"]}, [:deterministic])
    "watch:" <> Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end

  @spec decorate(row :: map(), task :: map() | nil, history :: [map()]) :: map()
  def decorate(row, task, history) do
    latest = List.first(history) || %{}
    started = if task, do: task.started_at, else: timestamp(latest["created_at"])
    finished = if task, do: task.finished_at, else: timestamp(latest["finished_at"])
    duration = if task, do: task.duration_ms, else: duration(latest)

    Map.merge(row, %{
      active?: active?(row),
      status_label: Record.status_name(row.status),
      tracking_label: tracking(row),
      started_at: started,
      finished_at: finished,
      sort_time: finished || started || "",
      elapsed: elapsed(duration),
      history:
        Enum.map(history, &"#{Record.status_name(&1["status"])} · #{history_label(&1, row)}")
    })
  end

  defp active?(row),
    do: row.running? or row.watching? or (row.observation == "completed" and not row.delivered?)

  defp history_label(%{"source" => "background"}, row), do: row.label
  defp history_label(watch, _row), do: Record.label(watch)

  defp tracking(%{source: "background", running?: false, status: "cancelled"}),
    do: "Command cancelled · automatic continuation revoked"

  defp tracking(%{running?: true, watching?: false, observation: "stopped"}),
    do: "Tracking paused · command still running"

  defp tracking(%{watching?: true}), do: "Tracking automatically"

  defp tracking(%{observation: "stopped"}),
    do: "Tracking paused · external work was not cancelled"

  defp tracking(%{observation: "completed", delivered?: false}),
    do: "Waiting for the agent to become idle"

  defp tracking(%{delivered?: true}), do: "Result delivered"
  defp tracking(_row), do: ""

  defp timestamp(value) when is_integer(value),
    do: value |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp timestamp(_value), do: nil

  defp duration(%{"created_at" => start} = watch) when is_integer(start),
    do: max((watch["finished_at"] || System.system_time(:millisecond)) - start, 0)

  defp duration(_watch), do: 0

  defp elapsed(ms) when ms < 1000, do: "<1s"
  defp elapsed(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp elapsed(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp elapsed(ms), do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"
end
