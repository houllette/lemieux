defmodule Lemieux.CompactionTest do
  @moduledoc """
  Choosing where to cut, and reading a cut that was already made.

  The cut rules are the dangerous part. A conversation split between a
  model's tool call and the result of that tool call is one every provider
  rejects outright, so the boundary rule here is not a nicety — it is the
  difference between a session that compacts and a session that stops working
  the moment it does.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Compaction
  alias Lemieux.Entry
  alias Lemieux.Tool.Attachment

  defp entry(type, payload \\ %{}), do: Entry.new(type, payload)

  # A turn: a prompt, an assistant message calling a tool, its result, and the
  # assistant's answer. Cutting anywhere inside one is what must not happen.
  defp turn do
    [
      entry(:user, %{"text" => "do a thing"}),
      entry(:assistant, %{"tool_calls" => [%{"id" => "t1", "name" => "read"}]}),
      entry(:tool_result, %{"id" => "t1", "output" => "contents"}),
      entry(:assistant, %{"content" => [%{"type" => "text", "text" => "done"}]})
    ]
  end

  defp turns(count), do: Enum.flat_map(1..count, fn _n -> turn() end)

  # The module is the default implementation of the behaviour it declares, so
  # the two cannot drift: every callback answers exactly as the pure function
  # it fronts, whatever state it is handed.
  describe "as its own default" do
    test "declares the behaviour it implements" do
      behaviours =
        Compaction.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Compaction in behaviours
    end

    test "the callbacks answer as the functions do, and ignore the state" do
      entries = turns(10)

      assert Compaction.plan(:any, entries, keep: 0.5) == Compaction.plan(entries, keep: 0.5)
      assert Compaction.applied(:any, entries, []) == Compaction.applied(entries)
      assert Compaction.conversation?(:any, entries) == Compaction.conversation?(entries)
      assert Compaction.summary(:any, entries) == Compaction.summary(entries)

      assert Compaction.sections(:any, "## Decisions\n- one") ==
               Compaction.sections("## Decisions\n- one")

      assert Compaction.instructions(:any, "before", sections: true) ==
               Compaction.instructions("before", sections: true)

      assert Compaction.with_summary(:any, "sys", "sum") == Compaction.with_summary("sys", "sum")
    end
  end

  describe "planning a cut" do
    test "splits a long conversation into what is summarised and what is kept" do
      entries = turns(10)

      assert {:ok, plan} = Compaction.plan(entries)

      assert plan.elder != []
      assert plan.tail != []
      assert plan.elder ++ plan.tail == entries
    end

    test "the kept tail always begins at a turn boundary" do
      # Every tail must start with a user entry. Starting on a tool_result
      # would send a result for a call the model can no longer see, and
      # starting on an assistant tool call would send a call whose result was
      # summarised away.
      for count <- 4..14 do
        assert {:ok, plan} = Compaction.plan(turns(count))
        assert %Entry{type: :user} = List.first(plan.tail)
      end
    end

    test "a conversation with nothing worth summarising is left alone" do
      assert Compaction.plan(turn()) == :nothing_to_do
      assert Compaction.plan([]) == :nothing_to_do
    end

    test "a conversation with no boundary of either kind to cut at is left alone" do
      # Results with no assistant message calling them: every possible cut
      # would send a result for a call the model cannot see.
      entries = [entry(:user)] ++ Enum.map(1..40, fn _n -> entry(:tool_result) end)

      assert Compaction.plan(entries) == :nothing_to_do
    end

    test "one prompt and a long tool loop under it is cut at an assistant message" do
      # The commonest long session has no second user entry anywhere. It used to
      # be uncuttable, so it filled the window and died.
      rounds =
        Enum.flat_map(1..20, fn n ->
          [
            entry(:assistant, %{"tool_calls" => [%{"id" => "t#{n}", "name" => "read"}]}),
            entry(:tool_result, %{"call_id" => "t#{n}", "output" => "contents #{n}"})
          ]
        end)

      entries = [entry(:user, %{"text" => "fix the suite"}) | rounds]

      assert {:ok, plan} = Compaction.plan(entries)
      assert %Entry{type: :assistant} = List.first(plan.tail)
      assert %Entry{type: :tool_result} = List.last(plan.elder)
      assert plan.elder ++ plan.tail == entries
    end

    test "keeps more than it summarises is not required, but it keeps something" do
      assert {:ok, plan} = Compaction.plan(turns(20))

      assert length(plan.tail) >= 4
    end

    test "how much to keep can be asked for" do
      entries = turns(20)

      assert {:ok, small} = Compaction.plan(entries, keep: 0.1)
      assert {:ok, large} = Compaction.plan(entries, keep: 0.5)

      assert length(small.tail) < length(large.tail)
    end

    test "token target cuts a huge user span at an assistant boundary without orphaning tool results" do
      huge = entry(:user, %{"text" => String.duplicate("a", 8_000)})
      call = entry(:assistant, %{"tool_calls" => [%{"id" => "late", "name" => "read"}]})
      result = entry(:tool_result, %{"id" => "late", "output" => "ok"})
      answer = entry(:assistant, %{"content" => [%{"type" => "text", "text" => "done"}]})
      entries = turns(3) ++ [huge, call, result, answer]

      assert {:ok, plan} = Compaction.plan(entries, keep_recent_tokens: 100)
      assert List.first(plan.tail) == call
      assert plan.tail == [call, result, answer]
      assert List.last(plan.elder) == huge
    end

    # Every request leaves a `:request` record holding the whole system prompt
    # and tool catalog. The provider never sends it, so it must not use up the
    # retained tail: counted, the tail kept a third of what its target allowed.
    test "a token target counts only what is sent, not the request records between turns" do
      record = fn -> entry(:request, %{"system" => String.duplicate("s", 20_000)}) end

      entries =
        Enum.flat_map(1..6, fn n ->
          [
            entry(:user, %{"text" => "step #{n}"}),
            record.(),
            entry(:assistant, %{
              "content" => [%{"type" => "text", "text" => String.duplicate("a", 400)}]
            })
          ]
        end)

      assert {:ok, plan} = Compaction.plan(entries, keep_recent_tokens: 1_000)
      assert Enum.count(plan.tail, &(&1.type == :user)) == 5
    end

    test "token target cannot cut a user span with no assistant boundary" do
      entries = turns(2) ++ [entry(:user, %{"text" => String.duplicate("a", 8_000)})]

      assert Compaction.plan(entries, keep_recent_tokens: 100) == :nothing_to_do
    end
  end

  describe "a transcript that has been compacted" do
    setup do
      entries = turns(4)
      elder = Enum.take(entries, 8)
      tail = Enum.drop(entries, 8)

      compaction =
        entry(:compaction, %{
          "summary" => "They read two files.",
          "from" => List.first(elder).id,
          "to" => List.last(elder).id,
          "entries" => 8
        })

      %{entries: elder ++ [compaction] ++ tail, elder: elder, tail: tail}
    end

    test "sends the tail and not what was summarised", context do
      sent = Compaction.applied(context.entries)

      assert sent == context.tail

      for cut <- context.elder do
        refute Enum.any?(sent, &(&1.id == cut.id))
      end
    end

    test "the summary is available to put in front of the request", context do
      assert Compaction.summary(context.entries) == "They read two files."
    end

    test "an uncompacted transcript is sent whole, with no summary" do
      entries = turns(3)

      assert Compaction.applied(entries) == entries
      assert Compaction.summary(entries) == nil
    end

    test "a second compaction supersedes the first", context do
      second =
        entry(:compaction, %{
          "summary" => "They read four files.",
          "from" => List.first(context.tail).id,
          "to" => List.last(context.tail).id,
          "entries" => 8
        })

      later = entry(:user, %{"text" => "and now?"})
      entries = context.entries ++ [second, later]

      assert Compaction.applied(entries) == [later]
      assert Compaction.summary(entries) == "They read four files."
    end

    test "a compaction naming a cut point that is not there sends everything after it" do
      # Defensive rather than expected: a transcript edited by hand, or written
      # by a host with its own idea of ids. Sending too much is a request that
      # may be too large; sending too little is a conversation with a hole in
      # it, and the model cannot tell.
      entries = turns(2)
      compaction = entry(:compaction, %{"summary" => "s", "to" => "no-such-entry"})

      assert Compaction.applied(entries ++ [compaction]) == []
    end
  end

  describe "what the summariser is asked" do
    test "the instructions say what a summary is for, and mention the tail is kept" do
      assert Compaction.instructions() =~ "summar"
      assert String.length(Compaction.instructions()) > 200
    end

    test "a second compaction is told what the first one already summarised" do
      prompt = Compaction.instructions("They read two files.")

      assert prompt =~ "They read two files."
      assert prompt =~ "summarised before"
    end
  end

  describe "putting a summary in front of a request" do
    test "a session with no summary is left exactly as it was" do
      assert Compaction.with_summary("be helpful", nil) == "be helpful"
      assert Compaction.with_summary(nil, nil) == nil
    end

    test "a summary joins the system prompt rather than replacing it" do
      system = Compaction.with_summary("be helpful", "They read two files.")

      assert system =~ "be helpful"
      assert system =~ "They read two files."
    end

    test "a session with no system prompt still gets the summary" do
      assert Compaction.with_summary(nil, "They read two files.") =~ "They read two files."
    end
  end

  describe "applied/2 shedding attachments" do
    defp attached(path) do
      Entry.new(:user, %{
        "text" => "explain @#{path}",
        "attachments" => [
          %{"ref" => "@#{path}", "path" => path, "kind" => "file", "text" => "1\tcontents"}
        ]
      })
    end

    defp attachments(entry), do: entry.payload["attachments"]

    test "sheds nothing by default, so every other reader gets the transcript" do
      entries = [attached("a.ex"), attached("b.ex")]

      assert Compaction.applied(entries) == entries
    end

    test "keeps the newest prompts that carried attachments and notes the rest" do
      entries = [attached("a.ex"), attached("b.ex"), attached("c.ex")]

      assert [old, %Entry{} = kept_b, %Entry{} = kept_c] =
               Compaction.applied(entries, keep_attachments: 2)

      assert [%{"kind" => "elided", "path" => "a.ex", "text" => text}] = attachments(old)
      assert text =~ "no longer included"
      assert text =~ "read the file"

      assert [%{"kind" => "file"}] = attachments(kept_b)
      assert [%{"kind" => "file"}] = attachments(kept_c)
    end

    test "leaves the prompt itself alone, so the conversation still reads as it was typed" do
      entry = attached("a.ex")

      assert [shed] = Compaction.applied([entry], keep_attachments: 0)

      # Identity is preserved because this is a projection of the transcript,
      # not a new transcript: everything downstream still matches these
      # entries up against the stored ones by id.
      assert shed.id == entry.id
      assert shed.seq == entry.seq
      assert shed.parent_id == entry.parent_id
      assert shed.payload["text"] == "explain @a.ex"
    end

    test "counts only the prompts that carried something" do
      entries = [attached("a.ex"), Entry.new(:user, %{"text" => "plain"}), attached("b.ex")]

      assert [%Entry{} = first, plain, last] = Compaction.applied(entries, keep_attachments: 1)

      assert [%{"kind" => "elided"}] = attachments(first)
      assert plain.payload == %{"text" => "plain"}
      assert [%{"kind" => "file"}] = attachments(last)
    end

    test "sheds what survived the cut, not what the cut already removed" do
      old = attached("gone.ex")
      kept = attached("kept.ex")
      newer = attached("newer.ex")
      compaction = Entry.new(:compaction, %{"summary" => "a summary", "to" => old.id})

      assert [%Entry{} = shed, %Entry{} = held] =
               Compaction.applied([old, kept, compaction, newer], keep_attachments: 1)

      assert shed.payload["text"] == "explain @kept.ex"
      assert [%{"kind" => "elided"}] = attachments(shed)
      assert [%{"kind" => "file"}] = attachments(held)
    end
  end

  describe "applied/2 after a cut inside a turn" do
    setup do
      user = entry(:user, %{"text" => "fix the suite"})
      first = entry(:assistant, %{"tool_calls" => [%{"id" => "t1", "name" => "read"}]})
      result = entry(:tool_result, %{"call_id" => "t1", "output" => "one"})
      second = entry(:assistant, %{"tool_calls" => [%{"id" => "t2", "name" => "read"}]})
      later = entry(:tool_result, %{"call_id" => "t2", "output" => "two"})

      compaction =
        entry(:compaction, %{"summary" => "Asked to fix the suite.", "to" => result.id})

      %{entries: [user, first, result, compaction, second, later], second: second}
    end

    test "a tail beginning with an assistant message is led by a user message", context do
      assert [lead, %Entry{} = kept | _rest] = Compaction.applied(context.entries)

      assert lead.type == :user
      assert lead.payload["text"] =~ "summarised in the system prompt"
      assert lead.meta == %{"synthetic" => true}
      assert kept.id == context.second.id
    end

    test "the lead is the same every time, so a resumed session sends what the live one did",
         context do
      assert Compaction.applied(context.entries) == Compaction.applied(context.entries)
    end

    test "a tail that already begins with the person's own message is left alone" do
      entries = turns(3)

      refute Enum.any?(Compaction.applied(entries), &(&1.meta == %{"synthetic" => true}))
    end
  end

  describe "applied/2 and partial answers" do
    test "an answer kept only as a record of a retried request is never sent" do
      user = entry(:user, %{"text" => "go"})

      partial =
        entry(:assistant, %{
          "content" => [%{"type" => "text", "text" => "half an ans"}],
          "partial" => true
        })

      answer = entry(:assistant, %{"content" => [%{"type" => "text", "text" => "the answer"}]})

      assert Compaction.applied([user, partial, answer]) == [user, answer]
      assert Compaction.partial?(partial)
      refute Compaction.partial?(answer)
    end
  end

  describe "applied/2 stubbing old tool output" do
    defp results(count, bytes) do
      Enum.flat_map(1..count, fn n ->
        [
          entry(:assistant, %{"tool_calls" => [%{"id" => "t#{n}", "name" => "read"}]}),
          entry(:tool_result, %{
            "call_id" => "t#{n}",
            "name" => "read",
            "output" => String.duplicate("x", bytes),
            "structured_content" => %{"lines" => bytes}
          })
        ]
      end)
    end

    defp stubbed(entries),
      do: Enum.filter(entries, &((&1.payload["output"] || "") =~ "no longer included"))

    test "sends every result whole unless asked" do
      entries = [entry(:user, %{"text" => "go"}) | results(80, 5_000)]

      assert Compaction.applied(entries) == entries
    end

    test "stubs the oldest large results, a batch at a time" do
      entries = [entry(:user, %{"text" => "go"}) | results(70, 5_000)]
      sent = Compaction.applied(entries, stub_tool_results: [keep: 40, batch: 20])

      # 70 results, 40 kept: 30 are old enough, and one whole batch of 20 is stubbed.
      assert length(stubbed(sent)) == 20
      assert [first | _rest] = stubbed(sent)
      assert first.payload["output"] =~ "5000 bytes"
      refute Map.has_key?(first.payload, "structured_content")
    end

    test "the stubbed set does not move until a whole batch has aged" do
      opts = [stub_tool_results: [keep: 40, batch: 20]]
      base = [entry(:user, %{"text" => "go"}) | results(70, 5_000)]

      grown = base ++ results(9, 5_000)

      # Nine more results age nine more past the kept window, which is less than
      # a batch: the same twenty are stubbed, so the cached prefix is unchanged.
      assert Enum.map(stubbed(Compaction.applied(base, opts)), & &1.id) ==
               Enum.map(stubbed(Compaction.applied(grown, opts)), & &1.id)
    end

    test "small outputs are left alone, whatever their age" do
      entries = [entry(:user, %{"text" => "go"}) | results(80, 100)]

      assert stubbed(Compaction.applied(entries, stub_tool_results: [keep: 10, batch: 5])) == []
    end

    test "a stubbed result no longer carries its images" do
      [call, result] = results(1, 5_000)

      with_image =
        %{result | payload: Map.put(result.payload, "attachments", [screenshot("a.png")])}

      assert [_user, _call, stubbed_result] =
               Compaction.applied([entry(:user, %{"text" => "go"}), call, with_image],
                 stub_tool_results: [keep: 0, batch: 1]
               )

      refute Map.has_key?(stubbed_result.payload, "attachments")
    end
  end

  defp screenshot(path) do
    Attachment.new(:image, "image/png", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>, path: path)
  end

  describe "applied/2 shedding tool results' images" do
    defp shots(count) do
      Enum.flat_map(1..count, fn n ->
        [
          entry(:assistant, %{"tool_calls" => [%{"id" => "s#{n}", "name" => "browser"}]}),
          entry(:tool_result, %{
            "call_id" => "s#{n}",
            "name" => "browser",
            "output" => "[image: shot #{n}]",
            "attachments" => [screenshot("shot#{n}.png")]
          })
        ]
      end)
    end

    defp carrying(entries),
      do: Enum.filter(entries, &Map.has_key?(&1.payload, "attachments"))

    test "sends every image unless asked" do
      entries = [entry(:user, %{"text" => "go"}) | shots(10)]

      assert Compaction.applied(entries) == entries
    end

    test "sheds the oldest a batch at a time, and says so in their output" do
      entries = [entry(:user, %{"text" => "go"}) | shots(10)]
      sent = Compaction.applied(entries, keep_media: 4)

      # Ten carry images and four are kept: six are old enough, and one whole
      # batch of four is shed — the cached prefix moves once per four shots.
      assert length(carrying(sent)) == 6

      shed =
        Enum.filter(
          sent,
          &(&1.type == :tool_result and not Map.has_key?(&1.payload, "attachments"))
        )

      assert length(shed) == 4
      assert Enum.all?(shed, &(&1.payload["output"] =~ "no longer attached"))
      assert hd(shed).payload["output"] =~ "[image: shot 1]"
    end

    test "zero keeps none, and :all keeps every one" do
      entries = [entry(:user, %{"text" => "go"}) | shots(3)]

      assert carrying(Compaction.applied(entries, keep_media: 0)) == []
      assert length(carrying(Compaction.applied(entries, keep_media: :all))) == 3
    end

    # A screenshot is weighed as an image, not as a novel of base64: a plan
    # sized on its bytes would keep almost nothing of a browser session.
    test "an image is weighed at a flat image cost when estimating" do
      big = %{screenshot("big.png") | "data" => String.duplicate("A", 400_000)}

      light = entry(:tool_result, %{"output" => "shot", "attachments" => [big]})
      bare = entry(:tool_result, %{"output" => "shot"})

      assert (Compaction.estimated_tokens([light]) - Compaction.estimated_tokens([bare])) in 1_500..1_800
    end
  end

  describe "structured sections" do
    test "the instructions ask for them only when told to" do
      refute Compaction.instructions() =~ "## Open work"
      refute Compaction.instructions("older") =~ "## Open work"

      asked = Compaction.instructions(nil, sections: true)

      for heading <- Compaction.section_headings() do
        assert asked =~ "## " <> heading
      end

      # The previous summary still folds in, after the sections are asked for.
      with_previous = Compaction.instructions("what was kept before", sections: true)
      assert with_previous =~ "## Verification debt"
      assert with_previous =~ "what was kept before"
    end

    test "are read back from a summary that carries them" do
      summary = """
      The person asked for a parser, then narrowed it to tables.

      ## Open work
      - finish the parser
      - run the suite (must be green)

      ## Dependencies
      - the parser waits on the schema answer from the person

      ## Decisions
      * keep it opt-in, because the ADR gates it on evidence

      ## Verification debt
      none
      """

      assert Compaction.sections(summary) == %{
               open_work: ["finish the parser", "run the suite (must be green)"],
               dependencies: ["the parser waits on the schema answer from the person"],
               decisions: ["keep it opt-in, because the ADR gates it on evidence"],
               verification_debt: []
             }
    end

    test "a summary without them is nil, and a partial one has empty sections" do
      assert Compaction.sections("just prose about what happened") == nil
      assert Compaction.sections(nil) == nil

      assert Compaction.sections("## Open work\n1. the one thing") == %{
               open_work: ["the one thing"],
               dependencies: [],
               decisions: [],
               verification_debt: []
             }
    end

    test "headings are matched loosely: case, bold, a colon, a different level" do
      assert %{decisions: ["a"]} = Compaction.sections("**Decisions:**\n- a")
      assert %{verification_debt: ["b"]} = Compaction.sections("### VERIFICATION DEBT\n• b")
      assert %{open_work: ["c"]} = Compaction.sections("Open work:\nc")
    end

    test "prose before the first heading is not an item of anything" do
      assert %{open_work: ["x"], decisions: []} =
               Compaction.sections("Some context.\n\n## Open work\n- x\n\n## Decisions\nnothing")
    end
  end
end
