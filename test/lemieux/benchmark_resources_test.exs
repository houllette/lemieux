defmodule Lemieux.Benchmark.ResourcesTest do
  use ExUnit.Case, async: true
  alias Lemieux.Benchmark.Resources
  alias Lemieux.Entry

  test "cache conventions are additive once and compaction is charged separately" do
    entries =
      pair("c", "compaction", :compaction, %{
        "input_tokens" => 100,
        "cache_read_tokens" => 80,
        "input_includes_cached" => true,
        "output_tokens" => 5
      }) ++
        pair("s", "turn", :assistant, %{
          "input_tokens" => 20,
          "cache_read_tokens" => 80,
          "output_tokens" => 10
        })

    totals = Resources.from_entries(entries)
    assert totals["full_input_tokens"] == 200
    assert totals["uncached_input_tokens"] == 40
    assert totals["stages"]["compaction"]["full_input_tokens"] == 100
    assert totals["stages"]["turn"]["output_tokens"] == 10
    assert totals["tokens_complete"]
    assert totals["cost_usd"] == nil
  end

  test "missing counters and unanswered requests cannot make an efficiency win" do
    entries =
      pair("s", "turn", :assistant, %{"input_tokens" => 10}) ++
        [Entry.new(:request, %{"id" => "unanswered", "kind" => "compaction"})]

    totals = Resources.from_entries(entries)
    assert totals["requests"] == 2
    assert totals["reported_requests"] == 1
    assert totals["full_input_tokens"] == nil
    assert totals["output_tokens"] == nil
    assert totals["observed"]["full_input_tokens"] == 10
    refute totals["tokens_complete"]
  end

  test "per-success resources include failure costs and require complete coverage" do
    complete =
      Resources.from_entries(
        pair("s", "turn", :assistant, %{"input_tokens" => 10, "output_tokens" => 2})
      )

    run = %{"passed" => true, "wall_time_ms" => 20, "observation" => %{"resources" => complete}}
    summary = Resources.summarize([run, %{run | "passed" => false}])
    assert summary["per_success"]["full_input_tokens"] == 20
    assert summary["end_to_end_ms_per_success"] == 40
    missing = put_in(run, ["observation", "resources"], nil)
    incomplete = Resources.summarize([run, missing])
    refute incomplete["tokens_complete"]
    assert incomplete["per_success"]["full_input_tokens"] == nil
    assert incomplete["observed"]["full_input_tokens"] == 10
  end

  test "run totals include tokens spent by a discarded infrastructure retry" do
    retained = %{
      "passed" => true,
      "wall_time_ms" => 20,
      "observation" => %{
        "resources" => %{
          "tokens_complete" => true,
          "full_input_tokens" => 10,
          "output_tokens" => 2,
          "wall_time_ms" => 20
        }
      },
      "retries" => [
        %{
          "wall_time_ms" => 15,
          "resources" => %{
            "tokens_complete" => true,
            "full_input_tokens" => 7,
            "output_tokens" => 1,
            "wall_time_ms" => 15
          }
        }
      ]
    }

    summary = Resources.summarize([retained])
    assert summary["attempts"] == 1
    assert summary["executions"] == 2
    assert summary["tokens_complete"]
    assert summary["total"]["full_input_tokens"] == 17
    assert summary["total"]["output_tokens"] == 3
    assert summary["end_to_end_total_ms"] == 35
  end

  defp pair(id, kind, type, usage),
    do: [
      Entry.new(:request, %{"id" => id, "kind" => kind}),
      Entry.new(type, %{"request_id" => id}, usage: usage)
    ]
end
