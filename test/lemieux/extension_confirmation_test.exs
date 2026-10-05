defmodule Lemieux.ExtensionConfirmationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Contract
  alias Lemieux.Experiment.Plan
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Confirmation
  alias Lemieux.Learning.Extension.Confirmation.Evidence
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Tree

  @moduletag :tmp_dir

  setup_all do
    %{runtime: LemieuxTest.FrozenRuntime.create()}
  end

  setup %{tmp_dir: root, runtime: runtime} do
    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(Path.join(source, "mix.exs"), """
    defmodule ConfirmationFixture.MixProject do
      use Mix.Project
      def project, do: [app: :confirmation_fixture, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(source, "lib/fixture.ex"), """
    defmodule ConfirmationFixture do
      def configure(profile), do: {:ok, [answer: profile["options"]["answer"]], profile}
      def run(input, opts) do
        true = Enum.sort(Map.keys(input)) == [:cwd, :prompt, :timeout_ms]
        {:ok, %{"status" => "completed", "answer" => opts[:answer]}}
      end
    end
    """)

    File.write!(
      Path.join(source, "lemieux-extension.json"),
      JSON.encode!(%{
        "schema_version" => 1,
        "module" => "ConfirmationFixture",
        "files" => ["mix.exs", "lib/fixture.ex"]
      })
    )

    profile = %{
      "execution" => "scripted",
      "model" => "none",
      "tools" => [],
      "options" => %{"answer" => "no"}
    }

    {:ok, control} =
      Build.freeze(source, Path.join(root, "control"), profile, runtime_paths: runtime)

    {:ok, candidate} =
      Build.freeze(
        source,
        Path.join(root, "candidate"),
        put_in(profile, ["options", "answer"], "yes"),
        runtime_paths: runtime
      )

    evaluator = Path.join(root, "evaluator")
    File.mkdir!(evaluator)
    File.write!(Path.join(evaluator, "grade"), "#!/bin/sh\n[ \"$1\" = yes ]\n")
    File.chmod!(Path.join(evaluator, "grade"), 0o755)

    tasks =
      Enum.map(~w(dev fresh-a fresh-b), fn id ->
        cwd = Path.join(root, id)
        File.mkdir!(cwd)
        File.write!(Path.join(cwd, "input.txt"), id)

        %{
          "id" => id,
          "prompt" => "answer",
          "cwd" => cwd,
          "timeout_ms" => 10_000,
          "metadata" => %{"cluster_id" => id},
          "grader" => %{"command" => ["grade", "{answer}"]}
        }
      end)

    {:ok, manifest} = Manifest.from_map(%{"version" => 1, "tasks" => tasks}, root)

    {:ok, corpus} =
      Corpus.new(manifest, %{"dev" => :development, "fresh-a" => :holdout, "fresh-b" => :holdout})

    attrs = %{
      "hypothesis" => "fixture candidate passes more independent clusters",
      "metric" => %{"kind" => "continuous", "minimum_effect" => 0.1},
      "stopping_rule" => %{"minimum_pairs" => 2, "confidence" => 0.95},
      "budget" => %{"maximum_cost_usd" => 10},
      "extension_policy" => %{
        "repetitions" => 1,
        "maximum_cost_usd" => 10,
        "max_cost_per_attempt_usd" => 0.1,
        "maximum_mean_latency_ms" => 10_000,
        "unknown_cost" => "allow"
      }
    }

    %{control: control, candidate: candidate, corpus: corpus, attrs: attrs, evaluator: evaluator}
  end

  test "confirmed export binds the tested source and excludes all hidden material", context do
    assert {:ok, confirmation} = prepare(context)
    assert Bitwise.band(File.stat!(confirmation.root).mode, 0o777) == 0o700

    assert {:ok, %{"verdict" => "pass", "resources" => %{"cost_usd" => nil}}} =
             Confirmation.run(confirmation)

    assert {:ok, exposure} = Confirmation.exposure(confirmation)
    assert exposure.source_case_ids == ~w(fresh-a fresh-b)
    assert {:error, :eexist} = Confirmation.run(confirmation)
    destination = Path.join(context.tmp_dir, "installed")
    assert {:ok, receipt} = Confirmation.export(confirmation, destination)
    assert receipt["qualification"] == "confirmed"
    assert receipt["build_sha256"] == context.candidate.sha256
    assert receipt["production_active"] == false
    assert :ok = Export.verify(destination)
    assert :ok = Confirmation.verify_export(confirmation, destination, receipt)

    assert {:error, :confirmation_receipt_mismatch} =
             Confirmation.verify_export(
               confirmation,
               destination,
               Map.put(receipt, "build_sha256", "old-build")
             )

    refute JSON.encode!(receipt) =~ "fresh-a"
    assert {:ok, files} = Tree.files(destination)
    refute Enum.any?(Map.keys(files), &String.contains?(&1, "evaluator"))

    # A real second Mix host compiles the exported extension as a path dependency.
    host = Path.join(context.tmp_dir, "host")
    File.mkdir!(host)

    File.write!(Path.join(host, "mix.exs"), """
    defmodule ConfirmationHost.MixProject do
      use Mix.Project
      def project, do: [app: :confirmation_host, version: "0.1.0", deps: [{:confirmation_fixture, path: #{inspect(destination)}}]]
    end
    """)

    script = """
    profile = #{inspect(receipt["profile"])}
    {:ok, options, ^profile} = ConfirmationFixture.configure(profile)
    input = %{prompt: "smoke", cwd: File.cwd!(), timeout_ms: 1000}
    {:ok, result} = ConfirmationFixture.run(input, options)
    true = result["answer"] == "yes"
    {:ok, missed} = ConfirmationFixture.run(input, answer: "no")
    true = missed["answer"] == "no"
    IO.puts("confirmed-consumer-ok")
    """

    {output, status} =
      System.cmd("mix", ["run", "-e", script],
        cd: host,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "dev"},
          {"MIX_BUILD_PATH", Path.join(host, "_build")},
          {"MIX_DEPS_PATH", Path.join(host, "deps")}
        ]
      )

    assert status == 0, output
    assert output =~ "confirmed-consumer-ok"
  end

  test "quota confirmation reserves all attempts and fails closed on missing request evidence",
       context do
    quota_policy = %{
      "usage_mode" => "quota",
      "repetitions" => 1,
      "maximum_requests" => 8,
      "max_requests_per_attempt" => 2,
      "maximum_mean_latency_ms" => 10_000,
      "unknown_cost" => "allow"
    }

    attrs =
      context.attrs
      |> Map.put("budget", %{"usage_mode" => "quota", "maximum_requests" => 8})
      |> Map.put("extension_policy", quota_policy)

    assert {:ok, confirmation} = prepare(%{context | attrs: attrs})
    # This fixture completes without reporting request counts; unknown is not zero.
    assert {:ok,
            %{
              "verdict" => "inconclusive",
              "resources" => %{"passed" => false, "direct_requests" => nil}
            }} = Confirmation.run(confirmation)

    assert {:ok, report} = Tree.read(Path.join(confirmation.root, "report.json"))
    assert {:ok, receipt} = Tree.read(Path.join(confirmation.root, "frozen/confirmation.json"))
    assert {:ok, plan} = Plan.new(receipt["plan"])

    known =
      update_in(report, ["results"], fn rows ->
        Enum.map(rows, &put_in(&1, ["observation", "tool_metrics"], %{"requests" => 2}))
      end)

    assert {:ok, passed} = Evidence.evaluate(plan, quota_policy, receipt["tasks"], known)
    assert passed["verdict"] == "pass"
    assert passed["resources"]["direct_requests"] == 8
    assert passed["resources"]["cost_usd"] == nil

    excessive =
      update_in(known, ["results"], fn [first | rest] ->
        [put_in(first, ["observation", "tool_metrics", "requests"], 3) | rest]
      end)

    assert {:ok, failed} = Evidence.evaluate(plan, quota_policy, receipt["tasks"], excessive)
    assert failed["verdict"] == "inconclusive"
    assert failed["resources"]["passed"] == false

    invalid =
      put_in(receipt["plan"], ["budget"], %{
        "usage_mode" => "quota",
        "maximum_requests" => 0,
        "maximum_cost_usd" => 10
      })

    assert {:error, :invalid_budget} = Plan.new(invalid)

    insufficient =
      attrs
      |> put_in(["budget", "maximum_requests"], 7)
      |> put_in(["extension_policy", "maximum_requests"], 7)

    assert {:error, _} =
             Confirmation.prepare(
               Path.join(context.tmp_dir, "insufficient"),
               context.control,
               context.candidate,
               context.corpus,
               insufficient,
               evaluator_root: context.evaluator
             )
  end

  test "exposed cases, related clusters and renamed input duplicates are refused", context do
    {:ok, exposed} =
      Corpus.expose(context.corpus, ["fresh-a"], %{
        consumer_role: "developer",
        consumer_id: "owner"
      })

    assert {:error, :confirmation_case_exposed} = prepare(%{context | corpus: exposed})
    [dev, first, second] = context.corpus.manifest.tasks
    related = %{first | metadata: %{"cluster_id" => "dev"}}

    corpus = %{
      context.corpus
      | manifest: %{context.corpus.manifest | tasks: [dev, related, second]}
    }

    assert {:error, :exposed_cluster} = prepare(%{context | corpus: corpus})
    File.write!(Path.join(first.cwd, "input.txt"), "dev")
    assert {:error, :exposed_case_content} = prepare(context)
  end

  test "frozen evaluator mutation and stale handles fail before exposure", context do
    assert {:ok, confirmation} = prepare(context)

    assert {:error, :frozen_tree_changed} =
             Confirmation.open(confirmation.root, String.duplicate("0", 64))

    File.write!(Path.join(confirmation.root, "frozen/evaluator/grade"), "changed")
    assert {:error, :frozen_tree_changed} = Confirmation.run(confirmation)
    assert {:error, :enoent} = Confirmation.exposure(confirmation)
  end

  test "an interrupted budget-limited comparison consumes exposure and cannot export", context do
    attrs =
      context.attrs
      |> put_in(["budget", "maximum_cost_usd"], 0.1)
      |> put_in(["extension_policy", "maximum_cost_usd"], 0.1)

    assert {:ok, confirmation} = prepare(%{context | attrs: attrs})
    assert {:error, :incomplete_confirmation} = Confirmation.run(confirmation)
    assert {:ok, _exposure} = Confirmation.exposure(confirmation)
    assert {:error, :eexist} = Confirmation.run(confirmation)
    {:ok, report} = Tree.read(Path.join(confirmation.root, "report.json"))
    assert report["execution"]["scheduled"] == 1
    assert report["execution"]["planned"] == 4

    assert {:error, :enoent} =
             Confirmation.export(confirmation, Path.join(context.tmp_dir, "export"))
  end

  test "changing a dependency after evaluation invalidates the confirmed export", context do
    assert {:ok, confirmation} = prepare(context)
    assert {:ok, _result} = Confirmation.run(confirmation)

    File.write!(
      Path.join(
        confirmation.root,
        "frozen/variant/runtime/lemieux/ebin/Elixir.Lemieux.Agent.beam"
      ),
      "changed"
    )

    assert {:error, :frozen_tree_changed} =
             Confirmation.export(confirmation, Path.join(context.tmp_dir, "export"))
  end

  test "unknown usage cannot satisfy a declared dollar or token requirement", context do
    attrs = put_in(context.attrs, ["extension_policy", "unknown_cost"], "reject")
    assert {:ok, confirmation} = prepare(%{context | attrs: attrs})
    assert {:ok, %{"verdict" => "inconclusive"}} = Confirmation.run(confirmation)

    assert {:error, :confirmation_not_exportable} =
             Confirmation.export(confirmation, Path.join(context.tmp_dir, "export"))
  end

  test "missing attempts invalidate export even if a report digest is replaced", context do
    assert {:ok, confirmation} = prepare(context)
    assert {:ok, _result} = Confirmation.run(confirmation)
    report_path = Path.join(confirmation.root, "report.json")
    result_path = Path.join(confirmation.root, "result.json")
    {:ok, report} = Tree.read(report_path)
    {:ok, result} = Tree.read(result_path)
    report = Map.update!(report, "results", &tl/1)
    File.write!(report_path, JSON.encode!(report))

    File.write!(
      result_path,
      JSON.encode!(Map.put(result, "report_sha256", Contract.digest(report)))
    )

    assert {:error, :incomplete_confirmation} =
             Confirmation.export(confirmation, Path.join(context.tmp_dir, "export"))
  end

  test "repetitions and related cases do not inflate the independent sample", context do
    {:ok, confirmation} = prepare(context)
    {:ok, receipt} = Tree.read(Path.join(confirmation.root, "frozen/confirmation.json"))
    {:ok, plan} = Plan.new(receipt["plan"])
    tasks = Enum.map(receipt["tasks"], &put_in(&1, ["metadata", "cluster_id"], "same-cluster"))
    policy = Map.put(receipt["policy"], "repetitions", 5)

    rows =
      for task <- tasks, runtime <- ~w(control variant), attempt <- 1..5 do
        %{
          "task_id" => task["id"],
          "runtime" => runtime,
          "attempt" => attempt,
          "passed" => runtime == "variant",
          "error" => nil,
          "grader" => %{"timed_out" => false},
          "wall_time_ms" => 1,
          "observation" => %{
            "status" => "completed",
            "frozen_build_sha256" =>
              if(runtime == "variant", do: context.candidate.sha256, else: context.control.sha256)
          }
        }
      end

    assert {:ok, result} =
             Evidence.evaluate(plan, policy, tasks, %{
               "results" => rows,
               "execution" => %{"aborted" => false}
             })

    assert result["verdict"] == "inconclusive"
    assert result["quality"]["holdout"]["count"] == 1

    [first | rest] = rows
    unsafe = put_in(first, ["observation", "safety_violations"], ["outside_workspace"])

    assert {:ok, unsafe_result} =
             Evidence.evaluate(plan, policy, tasks, %{
               "results" => [unsafe | rest],
               "execution" => %{"aborted" => false}
             })

    assert unsafe_result["verdict"] == "safety_failure"

    expensive = put_in(first, ["observation", "usage"], %{"cost_usd" => 20})

    assert {:ok, costly_result} =
             Evidence.evaluate(plan, policy, tasks, %{
               "results" => [expensive | rest],
               "execution" => %{"aborted" => false}
             })

    assert costly_result["resources"]["cost_usd"] == nil
    assert costly_result["resources"]["observed_cost_usd"] == 20
    assert costly_result["resources"]["passed"] == false
  end

  defp prepare(context) do
    Confirmation.prepare(
      Path.join(context.tmp_dir, "confirmation"),
      context.control,
      context.candidate,
      context.corpus,
      context.attrs,
      evaluator_root: context.evaluator
    )
  end
end
