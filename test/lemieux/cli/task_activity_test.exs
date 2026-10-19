defmodule Lemieux.CLI.TaskActivityTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Tasks.Activity

  test "observations of the same activity share one stable row and retain contextual history" do
    first = watch("watch-first", 1000, "stopped")
    resumed = watch("watch-resumed", 2000, "watching")
    other = put_in(watch("watch-other", 1500, "watching"), ["target", "run_id"], "43")
    [group] = Activity.group([first, resumed])
    assert group.watch == resumed
    assert group.history == [resumed, first]
    assert Activity.id(first) == Activity.id(resumed)
    assert Activity.id(first) != Activity.id(other)
    assert length(Activity.group([first, resumed, other])) == 2
  end

  test "running work remains active when tracking is paused, with separate contextual states" do
    row = %{
      running?: true,
      watching?: false,
      observation: "stopped",
      status: "running",
      delivered?: true,
      label: "mix test"
    }

    task = %{started_at: "2026-10-19T20:00:00Z", finished_at: nil, duration_ms: 65_000}
    paused = watch("watch-first", 1000, "stopped")
    result = Activity.decorate(row, task, [paused])
    assert result.active?
    assert result.status_label == "Running"
    assert result.tracking_label == "Tracking paused · command still running"
    assert result.elapsed == "1m 5s"
    assert result.history == ["Tracking paused · build · run 42"]
  end

  test "same-millisecond observations follow causal order rather than random identifier order" do
    first = watch("watch-z-first", 1000, "stopped") |> Map.put("created_order", 1000)
    second = watch("watch-a-second", 1000, "watching") |> Map.put("created_order", 1001)
    assert [%{watch: ^second, history: [^second, ^first]}] = Activity.group([first, second])
  end

  test "completed work has a final status, time and history rather than another active row" do
    row = %{
      running?: false,
      watching?: false,
      observation: "completed",
      status: "success",
      delivered?: true,
      label: "mix test"
    }

    task = %{
      started_at: "2026-10-19T20:00:00Z",
      finished_at: "2026-10-19T20:01:05Z",
      duration_ms: 65_000
    }

    result = Activity.decorate(row, task, [])
    refute result.active?
    assert result.status_label == "Completed"
    assert result.finished_at == task.finished_at
    assert result.elapsed == "1m 5s"
  end

  defp watch(id, time, status),
    do: %{
      "id" => id,
      "source" => "build",
      "target" => %{"run_id" => "42"},
      "created_at" => time,
      "finished_at" => if(status == "watching", do: nil, else: time + 500),
      "status" => status
    }
end
