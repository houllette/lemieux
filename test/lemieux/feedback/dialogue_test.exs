defmodule Lemieux.Feedback.DialogueTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Feedback
  alias Lemieux.Feedback.Dialogue

  defp entries do
    [
      Entry.new(:user, %{"text" => "fix the failing test\nand run the formatter"}, seq: 0),
      Entry.new(:request, %{"id" => "req_1", "kind" => "turn"}, seq: 1),
      Entry.new(:tool_result, %{"name" => "bash", "error" => true, "output" => "boom"}, seq: 2),
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "done"}]}, seq: 3),
      Entry.new(:harness_snapshot, %{"id" => "snap"}, seq: 4)
    ]
  end

  defp answers(dialogue, lines) do
    Enum.reduce(lines, {:ask, dialogue}, fn line, outcome ->
      case outcome do
        {:ask, dialogue} -> Dialogue.answer(dialogue, line)
        {:retry, dialogue, _message} -> Dialogue.answer(dialogue, line)
        done -> done
      end
    end)
  end

  describe "anchors/1" do
    test "offers the moments a person recognises, newest first" do
      assert [assistant, tool, user] = Dialogue.anchors(entries())

      assert assistant.seq == 3 and assistant.label =~ "assistant"
      assert tool.label =~ "✗ bash boom"
      # The first line only, so a long prompt cannot fill the screen.
      assert user.label =~ "fix the failing test"
      refute user.label =~ "run the formatter"
    end

    test "leaves out bookkeeping nobody points at" do
      labels = entries() |> Dialogue.anchors() |> Enum.map(& &1.label)

      refute Enum.any?(labels, &(&1 =~ "request"))
      refute Enum.any?(labels, &(&1 =~ "harness_snapshot"))
    end

    test "is bounded, and empty for a session with nothing said yet" do
      many = for seq <- 0..40, do: Entry.new(:user, %{"text" => "line #{seq}"}, seq: seq)

      assert length(Dialogue.anchors(many)) == 10
      assert hd(Dialogue.anchors(many)).seq == 40
      assert Dialogue.anchors([]) == []
    end
  end

  describe "the dialogue" do
    setup do
      anchors = Dialogue.anchors(entries())
      {:ok, dialogue} = Dialogue.open(anchors)

      %{anchors: anchors, dialogue: dialogue}
    end

    test "refuses to open with nothing to anchor to" do
      assert Dialogue.open([]) == {:error, :nothing_to_anchor}
    end

    test "asks for prose first, then the anchor, then the three questions", ctx do
      assert Dialogue.question(ctx.dialogue) =~ "What should have gone differently?"

      assert {:ask, at_anchor} = Dialogue.answer(ctx.dialogue, "it never ran the formatter")
      assert Dialogue.question(at_anchor) =~ "Which moment is this about?"

      assert {:ask, at_type} = Dialogue.answer(at_anchor, "")
      assert Dialogue.question(at_type) =~ "What kind of feedback is this?"

      assert {:ask, at_scope} = Dialogue.answer(at_type, "bug")
      assert Dialogue.question(at_scope) =~ "How far does it reach?"

      assert {:ask, at_durability} = Dialogue.answer(at_scope, "project")
      assert Dialogue.question(at_durability) =~ "Once, or always?"

      assert {:done, submission} = Dialogue.answer(at_durability, "always")

      assert submission == %{
               text: "it never ran the formatter",
               entry_id: List.first(ctx.anchors).id,
               type: :bug,
               scope: :project,
               durability: :standing_rule,
               questions_asked: 3
             }
    end

    test "never asks a fourth question, and the record type refuses one anyway", ctx do
      assert {:done, submission} =
               answers(ctx.dialogue, ["it broke", "", "", "", "", "and another thing"])

      assert submission.questions_asked == 3

      {:ok, feedback} =
        Feedback.new("it broke", %{
          "host" => "test",
          "tenant_id" => "t",
          "project_id" => "p",
          "session_id" => "s",
          "entry_id" => "e"
        })

      assert {:error, :too_many_questions} =
               Feedback.revise(feedback, %{"questions_asked" => 4})
    end

    test "a number, a word and a blank all answer; anything else re-asks", ctx do
      {:ask, at_anchor} = Dialogue.answer(ctx.dialogue, "it broke")

      assert {:retry, still_at_anchor, message} = Dialogue.answer(at_anchor, "the second one")
      assert message =~ "choose 1 to 3"
      assert still_at_anchor.step == :anchor

      assert {:ask, at_type} = Dialogue.answer(still_at_anchor, "2")
      assert {:retry, still_at_type, _message} = Dialogue.answer(at_type, "severe")
      assert still_at_type.step == :type

      # The word, its atom name and its position all mean the same choice.
      for answer <- ["style", "style_preference", "4"] do
        assert {:ask, chosen} = Dialogue.answer(still_at_type, answer)
        assert chosen.type == :style_preference
      end
    end

    test "prose cannot be empty, because an empty record is evidence of nothing", ctx do
      assert {:retry, still_asking, message} = Dialogue.answer(ctx.dialogue, "   ")
      assert message =~ "feedback needs some words"
      assert still_asking.step == :text
    end

    test "prose supplied with the command skips the first question", ctx do
      {:ok, dialogue} = Dialogue.open(ctx.anchors, text: "the formatter never ran")

      assert dialogue.step == :anchor
      assert {:done, submission} = answers(dialogue, ["3", "missed", "global", "once"])
      assert submission.text == "the formatter never ran"
      assert submission.entry_id == Enum.at(ctx.anchors, 2).id
      assert submission.type == :missed_requirement
      assert submission.scope == :global
      assert submission.durability == :one_off
    end

    test "the words are handed over exactly as typed", ctx do
      typed = "It said `mix test` PASSED. It did not.  "
      assert {:done, submission} = answers(ctx.dialogue, [typed, "", "", "", ""])

      assert submission.text == String.trim(typed)
    end
  end
end
