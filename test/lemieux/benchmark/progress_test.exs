defmodule Lemieux.Benchmark.ProgressTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Progress

  @moduletag :tmp_dir

  test "prints attempt state and atomically maintains a status artifact", context do
    {:ok, output} = StringIO.open("")
    artifact = Path.join(context.tmp_dir, "progress.json")

    reporter =
      start_supervised!(
        {Progress,
         total: 2, label: "study", interval_ms: 60_000, output: output, artifact: artifact}
      )

    progress = Progress.callback(reporter)

    assert :ok =
             progress.(%{
               event: :attempt_started,
               id: {"task", "arm", 1},
               task_id: "task",
               runtime: "arm",
               attempt: 1,
               timeout_ms: 10_000
             })

    assert %{
             "active" => [
               %{
                 "task_id" => "task",
                 "timeout_ms" => 10_000,
                 "remaining_ms" => remaining,
                 "overdue" => false
               }
             ],
             "completed" => 0
           } = Progress.snapshot(reporter)

    assert remaining in 1..10_000

    send(reporter, :heartbeat)
    assert %{"active" => [_]} = Progress.snapshot(reporter)

    assert :ok =
             progress.(%{
               event: :attempt_finished,
               id: {"task", "arm", 1},
               task_id: "task",
               runtime: "arm",
               attempt: 1,
               passed: true,
               error: nil,
               finish_reason: ":stop",
               requests: 4,
               wall_time_ms: 2_000
             })

    assert :ok = Progress.finish(reporter)
    {_input, text} = StringIO.contents(output)
    assert text =~ "START study · 2 attempts"
    assert text =~ "[0/2] START arm · task"
    assert text =~ "[0/2] RUNNING arm · task"
    assert text =~ "deadline in"
    assert text =~ "[1/2] PASS arm · task · 00:02 · 4 requests"
    assert text =~ "DONE study · 1/2 attempts"

    persisted = artifact |> File.read!() |> JSON.decode!()
    assert persisted["status"] == "completed"
    assert persisted["completed"] == 1
    assert persisted["active"] == []
  end
end
