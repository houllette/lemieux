defmodule Lemieux.Subagent.ResultTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Group
  alias Lemieux.Subagent.Result

  defp definition do
    Definition.new(
      id: "scout",
      description: "Reads code",
      system_prompt: "Return findings",
      model: "test:model",
      tools: [Lemieux.Tools.Read],
      max_cost_usd: 0.2
    )
  end

  defp body(answer) do
    %{
      "answer" => answer,
      "findings" => [
        %{
          "claim" => "the session owns cancellation",
          "confidence" => "high",
          "evidence" => [
            %{"ref" => "lib/lemieux/session.ex", "locator" => "1707", "digest" => "abc"}
          ]
        }
      ],
      "artifacts" => [],
      "uncertainties" => [],
      "coverage" => %{"searched" => ["lib/lemieux"], "skipped" => []}
    }
  end

  defp entries(answer) do
    [
      Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => JSON.encode!(body(answer))}]
      })
    ]
  end

  test "runtime identity and provenance wrap a valid child body" do
    result =
      Result.from_session(
        "child-1",
        definition(),
        :ok,
        entries("Cancellation is centralized."),
        %{"input_tokens" => 10, "output_tokens" => 5, "cost_usd" => 0.01}
      )

    assert result.status == :ok
    assert result.answer == "Cancellation is centralized."
    assert result.definition_digest == Definition.digest(definition())
    assert [%{"evidence" => [%{"digest" => "abc"}]}] = result.findings
  end

  # Strict about what it accepts, not about what it demands: a key the schema
  # never described is still refused everywhere, and nothing is required that
  # the schema does not describe. What changed is the demand — a `read`-only
  # child cannot produce an artifact digest, and asking for one rejected
  # finished investigations.
  test "the schema invents nothing and requires only what it describes" do
    Result.schema()
    |> object_schemas()
    |> Enum.each(fn schema ->
      assert schema["additionalProperties"] == false
      keys = schema["properties"] |> Map.keys() |> MapSet.new()
      assert MapSet.subset?(MapSet.new(schema["required"] || []), keys)
    end)

    assert Result.schema()["required"] == ["answer"]
  end

  test "an answer outside the schema is kept as prose rather than discarded" do
    prose = [
      Entry.new(:assistant, %{
        "content" => [
          %{"type" => "text", "text" => "The config is read from .lmx/config.json first."}
        ]
      })
    ]

    result = Result.from_session("child-1", definition(), :ok, prose, %{})

    assert result.status == :ok
    assert result.format == :prose
    assert result.answer == "The config is read from .lmx/config.json first."
    assert result.findings == []
    assert [uncertainty] = result.uncertainties
    assert uncertainty =~ "outside the result schema"
    assert uncertainty =~ "not validated"
  end

  test "a fenced JSON body is unwrapped and validates as structured" do
    fenced = "```json\n" <> JSON.encode!(body("fenced but valid")) <> "\n```"
    entries = [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => fenced}]})]

    result = Result.from_session("child-1", definition(), :ok, entries, %{})

    assert result.format == :structured
    assert result.answer == "fenced but valid"
    assert [%{"claim" => _claim}] = result.findings
    assert Result.unfenced("```\n{\"a\": 1}\n```") == ~s({"a": 1})
    assert Result.unfenced("plain text") == "plain text"
  end

  test "a child that cannot compute a digest still reports its artifacts and findings" do
    body = %{
      "answer" => "two callers",
      "findings" => [
        %{
          "claim" => "only session.ex calls it",
          "confidence" => "medium",
          "evidence" => [%{"ref" => "lib/lemieux/session.ex", "locator" => "1707"}]
        }
      ],
      "artifacts" => [%{"kind" => "file", "ref" => "lib/lemieux/session.ex"}]
    }

    entries = [
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => JSON.encode!(body)}]})
    ]

    result = Result.from_session("child-1", definition(), :ok, entries, %{})

    assert result.format == :structured
    assert result.answer == "two callers"
    assert [%{"ref" => "lib/lemieux/session.ex"} = artifact] = result.artifacts
    refute Map.has_key?(artifact, "digest")
    assert [%{"evidence" => [evidence]}] = result.findings
    refute Map.has_key?(evidence, "digest")
    # Absent coverage is absent coverage, not a rejected envelope.
    assert result.coverage == %{"searched" => [], "skipped" => []}
  end

  test "a child that produced no answer at all is still a failure" do
    assert %{status: :failed, answer: ""} =
             Result.from_session("child-1", definition(), :ok, [], %{})

    empty = [Entry.new(:assistant, %{"content" => []})]
    result = Result.from_session("child-1", definition(), :ok, empty, %{})

    assert result.status == :failed
    assert [reason] = result.uncertainties
    assert reason =~ "no answer"
  end

  test "an oversized prose answer is clipped and says so" do
    long = String.duplicate("a", 40 * 1024)
    entries = [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => long}]})]

    result = Result.from_session("child-1", definition(), :ok, entries, %{})

    assert result.format == :prose
    assert byte_size(result.answer) == 32 * 1024
    assert Enum.any?(result.uncertainties, &(&1 =~ "clipped"))
  end

  # Three scouts in one session on 2026-09-18 each wrote a valid body with a long
  # answer, and each was demoted to prose over the length — losing the
  # findings and coverage the schema is for. The answer gives; the rest stays.
  test "a structured body with an over-long answer keeps its findings and is clipped" do
    long = String.duplicate("b", 40 * 1024)
    body = body(long)

    entries = [
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => JSON.encode!(body)}]})
    ]

    result = Result.from_session("child-1", definition(), :ok, entries, %{})

    assert result.format == :structured
    assert byte_size(result.answer) == 32 * 1024
    assert length(result.findings) == 1
    assert result.coverage["searched"] == ["lib/lemieux"]
    assert Enum.any?(result.uncertainties, &(&1 =~ "clipped"))
  end

  test "format survives a round trip through the durable payload" do
    prose = [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "just words"}]})]
    result = Result.from_session("child-1", definition(), :ok, prose, %{})

    assert result |> Result.to_map() |> Map.get("format") == "prose"
    assert {:ok, restored} = result |> Result.to_map() |> Result.from_map()
    assert restored.format == :prose

    # An envelope written before the field existed reads as structured, which
    # is what every accepted one was.
    legacy = result |> Result.to_map() |> Map.delete("format")
    assert {:ok, %{format: :structured}} = Result.from_map(legacy)
  end

  # Three scouts in one session were streaming complete answers when their
  # deadline fired, and the envelope gave the parent `""` for all three. The
  # text is kept and labelled; the status is what says it was not finished.
  test "a child stopped while answering keeps what it wrote, without being promoted" do
    partial = [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "partial"}]})]

    result = Result.from_session("child-1", definition(), :timeout, partial, %{})

    assert result.status == :timeout
    assert result.format == :prose
    assert result.answer == "partial"
    assert result.findings == []
    assert ["the child exceeded its deadline", cut] = result.uncertainties
    assert cut =~ "stopped while answering"
    assert cut =~ "not validated"
  end

  # A last turn that also called tools is narration on the way to an answer,
  # not the answer: "let me read the tests" handed to the parent as findings
  # would be worse than nothing.
  test "a last turn that called tools is not kept as an answer" do
    narrating = [
      Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => "Let me read the tests."}],
        "tool_calls" => [%{"id" => "c1", "name" => "read", "arguments" => %{"path" => "test"}}]
      })
    ]

    result = Result.from_session("child-1", definition(), :failed, narrating, %{})

    assert result.answer == ""
    assert result.uncertainties == ["the child failed before returning a valid result"]
  end

  test "failed envelopes preserve the recorded provider reason" do
    entries = [Entry.new(:error, %{"reason" => "the provider rejected the result schema"})]

    result = Result.from_session("child-1", definition(), :failed, entries, %{})

    assert result.uncertainties == ["the provider rejected the result schema"]
  end

  test "group aggregates preserve input order and unknown cost" do
    ok = Result.from_session("child-1", definition(), :ok, entries("one"), usage(10, 2, 0.01))
    failed = Result.from_session("child-2", definition(), :failed, [], usage(4, 1, nil))

    result = Group.Result.new("group-1", "parent-1", [ok, failed])

    assert result.status == :partial
    assert Enum.map(result.results, & &1.child_id) == ["child-1", "child-2"]
    assert result.usage["input_tokens"] == 14
    assert result.usage["cost_usd"] == nil
  end

  defp usage(input, output, cost) do
    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0,
      "cost_usd" => cost
    }
  end

  defp object_schemas(%{"type" => "object", "properties" => properties} = schema) do
    [schema | Enum.flat_map(properties, fn {_name, child} -> object_schemas(child) end)]
  end

  defp object_schemas(%{"type" => "array", "items" => items}), do: object_schemas(items)
  defp object_schemas(_schema), do: []

  # The renderer used to cut the encoded document down the middle: one parent
  # session received three answers as one blob, invalid from the second child
  # onward, with 6 KB gone and a note where the JSON should have closed. What
  # is cut is now said, and what remains parses.
  describe "rendering a group result to a budget" do
    defp child(id, answer) do
      Result.from_session(id, definition(), :ok, entries(answer), %{})
    end

    test "fits by clipping the longest answers first, and is always a document" do
      long = String.duplicate("L", 20_000)
      medium = String.duplicate("M", 8_000)
      short = String.duplicate("S", 1_000)

      group =
        Group.Result.new("g", "p", [child("a", long), child("b", medium), child("c", short)])

      rendered = Group.Result.render(group, 20_000)

      assert byte_size(rendered) <= 20_000
      assert {:ok, %{"results" => [a, b, c]}} = JSON.decode(rendered)

      # The short answer is untouched; the long one gave first.
      assert c["answer"] == short
      assert byte_size(a["answer"]) < 20_000
      assert a["answer"] =~ "clipped by lemieux"
      assert Enum.any?(a["uncertainties"], &(&1 =~ "bytes of the answer were clipped"))
      assert byte_size(b["answer"]) <= 8_000 + 100
    end

    test "renders untouched when it fits" do
      group = Group.Result.new("g", "p", [child("a", "short")])
      rendered = Group.Result.render(group, 120_000)

      assert {:ok, %{"results" => [%{"answer" => "short"}]}} = JSON.decode(rendered)
      refute rendered =~ "clipped"
    end
  end
end
