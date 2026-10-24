defmodule Lemieux.CLI.Learning.ReflectionTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Learning.Reflection.SharedValues
  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Experience.Retrieval.Evidence
  alias Lemieux.Providers.Scripted
  alias LemieuxTest.LessonFixtures, as: F
  @moduletag :tmp_dir

  test "retained compacted evidence keeps valid citations and expands to the exact complete source" do
    text = String.duplicate("complete source evidence λ\n", 500)

    observation = %{
      "source_observation_sha256" => Contract.sha256("captured source"),
      "transcript" =>
        for index <- 1..90 do
          %{
            "id" => "entry-#{index}",
            "type" => "tool_result",
            "seq" => index,
            "payload" => %{"output" => text}
          }
        end
    }

    record = %{"original" => observation, "selected" => observation}

    attrs = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" => "Inspect the complete retained source before adapting the workflow.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/text_table/t0"]
    }

    assert byte_size(Contract.encode!(record)) > Reflection.source_limit()

    assert {:ok, lesson} =
             Reflection.build(
               record,
               "large",
               %{scope: F.scope(), lesson_context: F.context()},
               attrs
             )

    assert lesson.qualification == "unconfirmed"
    assert :ok = Lesson.verify(lesson)
    assert {:ok, ^lesson} = lesson |> Lesson.encode!() |> Lesson.decode()
    assert {:ok, evidence, []} = Evidence.materialize([lesson], 2_097_152, 1_048_576)
    [artifact] = evidence[lesson.id <> ".json"]["artifacts"]
    refute artifact["truncated"]
    assert artifact["content"]["text_table"]["t0"] == text
    assert {:ok, ^record} = SharedValues.expand(artifact["content"])
  end

  test "compaction cannot admit unknown source fields or unrepeated oversized text", %{
    tmp_dir: dir
  } do
    supervisor = :"reflection_bound_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    text = String.duplicate("one complete public output ", 50_000)

    private = %{
      "original" => %{
        "transcript" =>
          List.duplicate(
            %{
              "id" => "entry",
              "seq" => 1,
              "type" => "tool_result",
              "payload" => %{"output" => String.duplicate("bounded public ", 40_000)}
            },
            3
          )
      },
      "private_grades" => %{"passed" => true}
    }

    assert Reflection.prepare(private) != private

    for record <- [%{"original" => %{"answer" => text}}, private] do
      provider = Scripted.new([Scripted.complete("must not dispatch")])

      assert {:error, :reflection_incomplete_or_invalid} =
               Reflection.distill(record,
                 model: "test:model",
                 effort: "default",
                 cwd: dir,
                 supervisor: supervisor,
                 sessions_dir: Path.join(dir, "sessions"),
                 provider: provider
               )

      assert Scripted.requests(provider) == []
    end
  end

  test "repeated complete public text fits the existing wire bound without losing source bytes",
       %{tmp_dir: dir} do
    supervisor = :"reflection_compact_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    output = String.duplicate("complete public output with unicode λ\n", 400)

    entries =
      for index <- 1..80 do
        %{
          "id" => "entry-#{index}",
          "type" => "tool_result",
          "seq" => index,
          "payload" => %{"output" => output, "unique" => "observation-#{index}"}
        }
      end

    record = %{"original" => %{"transcript" => entries}}
    assert byte_size(Contract.encode!(record)) > Reflection.source_limit()

    hypothesis = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" => "Review the complete public evidence before changing the workflow.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/text_table/t0"]
    }

    provider =
      Scripted.new([
        Scripted.complete(JSON.encode!(%{"lessons" => [hypothesis]}),
          usage: %{"input_tokens" => 2, "output_tokens" => 2}
        )
      ])

    assert {:ok, [^hypothesis], _} =
             Reflection.distill(record,
               model: "test:model",
               effort: "default",
               cwd: dir,
               supervisor: supervisor,
               sessions_dir: Path.join(dir, "sessions"),
               provider: provider
             )

    assert length(Scripted.requests(provider)) == 1
  end

  test "a malformed citation receives one bounded repair and a second malformed answer refuses",
       %{tmp_dir: dir} do
    supervisor = :"reflection_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    hypothesis = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" => "Verify the active source.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/original/transcript/0"]
    }

    good = JSON.encode!(%{"lessons" => [hypothesis]})

    bad =
      JSON.encode!(%{
        "lessons" => [Map.put(hypothesis, "source_pointers", ["/original/transcript/999"])]
      })

    record = %{
      "original" => %{
        "transcript" => [
          %{
            "id" => "entry",
            "type" => "tool_result",
            "seq" => 999,
            "payload" => %{"output" => "verified"}
          }
        ]
      }
    }

    opts = [
      model: "test:model",
      effort: "default",
      cwd: dir,
      supervisor: supervisor,
      sessions_dir: Path.join(dir, "sessions")
    ]

    provider =
      Scripted.new(
        Enum.map(
          [bad, good],
          &Scripted.complete(&1,
            usage: %{"input_tokens" => 2, "output_tokens" => 2}
          )
        )
      )

    assert {:ok, [^hypothesis], observation} =
             Reflection.distill(record, Keyword.put(opts, :provider, provider))

    assert length(observation["reflection_attempts"]) == 2

    provider =
      Scripted.new(
        Enum.map(
          [bad, bad, good],
          &Scripted.complete(&1,
            usage: %{"input_tokens" => 2, "output_tokens" => 2}
          )
        )
      )

    assert {:error, :reflection_incomplete_or_invalid} =
             Reflection.distill(record, Keyword.put(opts, :provider, provider))
  end

  test "trajectory projection preserves full tool output and references omitted repeated metadata" do
    output = String.duplicate("x", 5000)
    entry = %{"id" => "tool", "type" => "tool_result", "payload" => %{"output" => output}}

    request = %{
      "id" => "request",
      "type" => "request",
      "payload" => %{"catalog" => ["large repeated catalog"]}
    }

    observation = %{"transcript" => [request, entry], "answer" => "done"}
    projected = Reflection.project(observation)
    assert projected["transcript"] == [entry]
    assert [%{"id" => "request", "sha256" => digest}] = projected["metadata_references"]
    assert digest == Contract.digest(request)
    assert projected["source_observation_sha256"] == Contract.digest(observation)

    assert [%{"pointer" => "/original/transcript/0", "entry_id" => "tool"}] =
             Reflection.citation_index(%{"original" => projected})
  end

  test "a rejected experiment retains a source-backed negative lesson, not activation authority" do
    record = %{
      "original" => %{"status" => "completed", "transcript" => ["checked active source"]},
      "refinement" => %{
        "decision" => "baseline",
        "candidates" => [%{"evaluations" => [%{"score" => 0}]}]
      }
    }

    attrs = %{
      "kind" => "proposer_lesson",
      "outcome" => "rejected",
      "mechanism" =>
        "Changing only the source left the generated copy stale; inspect the build path before retrying.",
      "applicability" => ["generated source build workflow"],
      "source_pointers" => ["/refinement/candidates/0/evaluations/0"]
    }

    assert {:ok, lesson} =
             Reflection.build(
               record,
               "task-a",
               %{scope: F.scope(), lesson_context: F.context()},
               attrs
             )

    assert :ok = Lesson.verify(lesson)
    assert lesson.outcome == "rejected"
    assert lesson.qualification == "unconfirmed"
    assert lesson.source_case_ids == ["task-a"]
    assert lesson.contradicting != []
    assert lesson.provenance["source_pointers"] == attrs["source_pointers"]
    assert lesson.mechanism == attrs["mechanism"]
  end

  test "whole successful and uncertain task records qualify as observations without capture events" do
    for outcome <- ~w(supported insufficient_evidence) do
      attrs = %{
        "kind" => "procedure",
        "outcome" => outcome,
        "mechanism" => "Verify the active generated output after rebuilding.",
        "applicability" => ["repository workflow"],
        "source_pointers" => ["/original/transcript/0"]
      }

      record = %{
        "original" => %{
          "transcript" => [%{"command" => "make generate && python3 -m unittest", "exit" => 0}]
        }
      }

      assert {:ok, lesson} =
               Reflection.build(
                 record,
                 "task-a",
                 %{scope: F.scope(), lesson_context: F.context()},
                 attrs
               )

      assert lesson.outcome == outcome
      assert lesson.qualification == "unconfirmed"
      assert lesson.supporting != []
    end
  end

  test "a large complete combined record survives retention within the lesson wire bound" do
    record = %{"original" => %{"transcript" => [String.duplicate("x", 860_000)]}}

    attrs = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" => "Inspect complete source evidence before adopting a workflow.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/original/transcript/0"]
    }

    context = %{scope: F.scope(), lesson_context: F.context()}
    assert byte_size(Contract.encode!(record)) > 786_432
    assert {:ok, lesson} = Reflection.build(record, "combined", context, attrs)
    bytes = Lesson.encode!(lesson)
    assert byte_size(bytes) < 2_097_152
    assert {:ok, ^lesson} = Lesson.decode(bytes)

    oversized =
      put_in(record, ["original", "transcript"], [
        String.duplicate("x", Reflection.source_limit())
      ])

    assert {:error, :invalid_reflection_record} =
             Reflection.build(oversized, "too-large", context, attrs)
  end

  test "expanded disclosure makes cited trajectory bytes readable beyond the default excerpt" do
    output = String.duplicate("prefix ", 1000) <> "the active artifact stayed stale"
    record = %{"original" => %{"transcript" => [%{"output" => output}]}}

    attrs = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" => "Verify the active generated artifact.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/original/transcript/0/output"]
    }

    assert {:ok, lesson} =
             Reflection.build(
               record,
               "a",
               %{scope: F.scope(), lesson_context: F.context()},
               attrs
             )

    assert {:ok, bounded, []} = Evidence.materialize([lesson], 32_768)
    [artifact] = bounded[lesson.id <> ".json"]["artifacts"]
    assert artifact["truncated"]
    assert {:ok, expanded, []} = Evidence.materialize([lesson], 131_072, 65_536)
    [artifact] = expanded[lesson.id <> ".json"]["artifacts"]
    refute artifact["truncated"]

    assert get_in(artifact, ["content", "original", "transcript", Access.at(0), "output"]) ==
             output
  end

  test "fabricated citations, private feedback and unbounded hypotheses are refused" do
    record = %{"original" => %{"status" => "completed"}}

    attrs = %{
      "kind" => "procedure",
      "outcome" => "supported",
      "mechanism" => "Check the active source.",
      "applicability" => ["workflow"],
      "source_pointers" => ["/original/status"]
    }

    context = %{scope: F.scope(), lesson_context: F.context()}

    assert {:error, _} =
             Reflection.build(
               record,
               "a",
               context,
               Map.put(attrs, "source_pointers", ["/imagined/0"])
             )

    assert {:error, _} =
             Reflection.build(Map.put(record, "private_grade", %{}), "a", context, attrs)

    assert {:error, _} =
             Reflection.build(
               record,
               "a",
               context,
               Map.put(attrs, "mechanism", String.duplicate("x", 4097))
             )

    assert {:error, _} =
             Reflection.build(record, "a", context, Map.put(attrs, "source_pointers", []))
  end
end
