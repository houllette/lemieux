defmodule Lemieux.Benchmark.JudgingTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Judging
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  test "runs custom Tribunal judges through an injected LLM and caches unchanged inputs",
       context do
    parent = self()

    llm = fn model, messages, _opts ->
      send(parent, {:judged, model, messages})
      {:ok, %{"verdict" => "yes", "reason" => "matches the patch", "score" => 0.95}}
    end

    cache = Path.join(context.tmp_dir, "judge-cache.json")

    assert {:ok, judged} =
             Judging.run(report(),
               model: "openai:gpt-5-mini",
               threshold: 0.8,
               cache: cache,
               llm: llm
             )

    assert_receive {:judged, "openai:gpt-5-mini", messages}
    assert inspect(messages) =~ "explanation"
    assert judged["evaluation"]["runtimes"]["candidate"]["output_quality"]["rate"] == 1.0
    assert judged["gate"]["passed"]

    assert {:ok, cached} =
             Judging.run(report(),
               model: "openai:gpt-5-mini",
               threshold: 0.8,
               cache: cache,
               llm: fn _model, _messages, _opts -> flunk("cache miss") end
             )

    assert cached["results"] == judged["results"]
  end

  test "a judged failure is a threshold failure, not a hard safety failure", context do
    llm = fn _model, _messages, _opts ->
      {:ok, %{"verdict" => "no", "reason" => "claims an unmade change", "score" => 0.1}}
    end

    assert {:ok, judged} =
             Judging.run(report(), llm: llm, cache: Path.join(context.tmp_dir, "cache.json"))

    refute judged["gate"]["passed"]

    assert Enum.any?(judged["gate"]["failures"], fn failure ->
             failure["metric"] == "output_quality" and not failure["hard"]
           end)
  end

  test "the built-in judge uses the host provider and structured-output seam" do
    verdict = %{"verdict" => "yes", "reason" => "matches the patch", "score" => 0.95}

    provider =
      Scripted.new([
        [
          {:message, %{"content" => [%{"type" => "text", "text" => JSON.encode!(verdict)}]}},
          {:usage, %{"input_tokens" => 15, "output_tokens" => 10}},
          {:done, :stop}
        ]
      ])

    assert {:ok, judged} = Judging.run(report(), provider: provider, model: "ixway:team/coding")
    assert judged["gate"]["passed"]
    assert judged["judge"]["model"] == "ixway:team/coding"
    assert judged["judge"]["usage"]["input_tokens"] == 15
    assert judged["judge"]["usage"]["cost_usd"] == nil
    assert [request] = Scripted.requests(provider)
    assert request.model == "ixway:team/coding"
    assert request.output_schema[:verdict][:required]
    assert request.tools == []
    assert Enum.any?(request.entries, &String.contains?(&1.payload["text"], "explanation"))
  end

  defp report do
    %{
      "manifest" => %{
        "tasks" => [
          %{
            "id" => "explain",
            "metadata" => %{"judges" => ["explanation_faithfulness"]}
          }
        ]
      },
      "results" => [
        %{
          "task_id" => "explain",
          "runtime" => "candidate",
          "attempt" => 1,
          "observation" => %{
            "answer" => "I changed lib/example.ex and the focused test passes.",
            "change_summary" => "lib/example.ex changed; focused test exit status 0"
          }
        }
      ],
      "evaluation" => %{"runtimes" => %{"candidate" => %{}}, "comparisons" => %{}},
      "gate" => %{"passed" => true, "failures" => []}
    }
  end
end
