defmodule Lemieux.Benchmark.BaselineTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Baseline

  @moduletag :tmp_dir

  test "blesses only a passing evaluated report and round-trips stable JSON", context do
    report = %{
      "schema_version" => 1,
      "manifest" => %{"metadata" => %{"suite" => "smoke"}},
      "evaluation" => %{
        "runtimes" => %{
          "candidate" => %{
            "task_success" => %{"applicable" => 3, "passed" => 3, "rate" => 1.0}
          }
        }
      },
      "gate" => %{"passed" => true}
    }

    assert {:ok, baseline} =
             Baseline.from_report(report, "candidate", version: "1.2.0", change: "release")

    assert baseline["kind"] == "lemieux_eval_baseline"
    assert baseline["version"] == "1.2.0"
    assert baseline["runtime"] == "candidate"

    path = Path.join(context.tmp_dir, "baseline.json")
    assert :ok = Baseline.write(path, baseline)
    assert {:ok, ^baseline} = Baseline.read(path)
  end

  test "refuses to bless a failed gate or malformed SemVer" do
    report = %{"gate" => %{"passed" => false}}

    assert {:error, :gate_failed} =
             Baseline.from_report(report, "candidate", version: "1.2.0")

    passing = %{"gate" => %{"passed" => true}, "evaluation" => %{"runtimes" => %{}}}

    assert {:error, {:invalid_version, "next"}} =
             Baseline.from_report(passing, "candidate", version: "next")
  end
end
