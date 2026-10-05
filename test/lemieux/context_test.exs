defmodule Lemieux.ContextTest do
  @moduledoc """
  Where a session stands in its context window.

  Two things are being measured and they are not the same number: **position**,
  which is how full the window is and therefore what decides compaction, and
  **spend**, which is what the session has cost. A long session that compacts
  twice has a small position and a large spend.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Context
  alias Lemieux.Entry

  defp entry(type, usage \\ nil) do
    Entry.new(type, %{"text" => "x"}, usage: usage)
  end

  defp usage(fields), do: Map.new(fields, fn {key, value} -> {to_string(key), value} end)

  describe "position" do
    test "is zero for a session that has not asked the model anything yet" do
      assert %Context{tokens: 0, measured?: false} = Context.position([])
    end

    test "is what the last request carried plus what it answered" do
      entries = [
        entry(:user),
        entry(:assistant, usage(input_tokens: 1_000, output_tokens: 200))
      ]

      assert %Context{tokens: 1_200, measured?: true} = Context.position(entries)
    end

    test "is the last request's, not the sum of every request's" do
      entries = [
        entry(:assistant, usage(input_tokens: 1_000, output_tokens: 100)),
        entry(:assistant, usage(input_tokens: 1_500, output_tokens: 100))
      ]

      # The second request already contained the first one's conversation, so
      # adding them would count the same tokens twice.
      assert %Context{tokens: 1_600} = Context.position(entries)
    end

    test "counts cache reads, which are context even when they are cheap" do
      # Anthropic reports cache reads outside input_tokens, and says so with
      # `input_includes_cached: false`. They still occupy the window.
      entries = [
        entry(
          :assistant,
          usage(
            input_tokens: 100,
            cached_tokens: 30_000,
            cache_creation_tokens: 2_000,
            output_tokens: 50,
            input_includes_cached: false
          )
        )
      ]

      assert %Context{
               tokens: 32_150,
               current: %{input: 100, cached: 30_000, cache_write: 2_000, output: 50}
             } = Context.position(entries)
    end

    test "does not count cache reads twice when a provider folds them into input" do
      # OpenAI reports cached tokens as a subset of the prompt, and req_llm
      # says so. Adding them would double-count a third of a long prompt.
      entries = [
        entry(
          :assistant,
          usage(
            input_tokens: 30_100,
            cached_tokens: 30_000,
            output_tokens: 50,
            input_includes_cached: true
          )
        )
      ]

      assert %Context{
               tokens: 30_150,
               current: %{input: 100, cached: 30_000, cache_write: 0, output: 50}
             } = Context.position(entries)
    end

    test "ignores entries that carry no usage, so a tool result does not reset it" do
      entries = [
        entry(:assistant, usage(input_tokens: 1_000, output_tokens: 100)),
        entry(:tool_result),
        entry(:tool_result)
      ]

      assert %Context{tokens: 1_100} = Context.position(entries)
    end

    test "is unmeasured again after a compaction, until the next answer arrives" do
      entries = [
        entry(:assistant, usage(input_tokens: 900_000, output_tokens: 100)),
        entry(:compaction)
      ]

      # The tokens that were measured are the ones compaction just removed, so
      # reporting them would compact again immediately, and again after that.
      assert %Context{tokens: 0, measured?: false, compacted?: true} = Context.position(entries)
    end

    test "is measured again by the first request after a compaction" do
      entries = [
        entry(:assistant, usage(input_tokens: 900_000, output_tokens: 100)),
        entry(:compaction),
        entry(:assistant, usage(input_tokens: 4_000, output_tokens: 100))
      ]

      assert %Context{tokens: 4_100, measured?: true, compacted?: false} =
               Context.position(entries)
    end

    test "invalidating a live position keeps accumulated usage intact" do
      measured =
        Context.position(
          [entry(:assistant, usage(input_tokens: 1_000, output_tokens: 100))],
          window: 10_000
        )

      compacted = Context.after_compaction(measured)

      assert %Context{tokens: 0, measured?: false, compacted?: true, fraction: nil} = compacted
      assert compacted.spent == measured.spent
      assert compacted.window == measured.window

      billed = Context.after_compaction(measured, usage(input_tokens: 20, output_tokens: 3))
      assert billed.spent.requests == measured.spent.requests + 1
      assert billed.spent.input == measured.spent.input + 20
      assert billed.spent.output == measured.spent.output + 3

      assert %Context{tokens: 50, compacted?: false} =
               Context.with_usage(compacted, usage(input_tokens: 45, output_tokens: 5))
    end
  end

  describe "the fraction of the window" do
    test "is nil when nobody knows how big the window is" do
      entries = [entry(:assistant, usage(input_tokens: 1_000, output_tokens: 0))]

      assert %Context{fraction: nil, window: nil} = Context.position(entries)
    end

    test "is the position over the window when somebody does" do
      entries = [entry(:assistant, usage(input_tokens: 40_000, output_tokens: 0))]

      assert %Context{fraction: fraction, window: 200_000} =
               Context.position(entries, window: 200_000)

      assert_in_delta fraction, 0.2, 0.001
    end

    test "does not exceed one, so a report cannot say 103% of a window" do
      entries = [entry(:assistant, usage(input_tokens: 300_000, output_tokens: 0))]

      assert %Context{fraction: 1.0} = Context.position(entries, window: 200_000)
    end
  end

  describe "live provider usage" do
    test "updates the current position without claiming a persisted request" do
      context = %Context{
        window: 100_000,
        spent: %{input: 10, output: 2, cached: 0, cache_write: 0, requests: 1}
      }

      live =
        Context.with_usage(
          context,
          usage(
            input_tokens: 30_100,
            cached_tokens: 30_000,
            output_tokens: 50,
            input_includes_cached: true
          )
        )

      assert live.current == %{input: 100, cached: 30_000, cache_write: 0, output: 50}
      assert live.tokens == 30_150
      assert_in_delta live.fraction, 0.3015, 0.0001
      assert live.spent == context.spent
    end
  end

  describe "spend" do
    test "is cumulative, and counts what compaction removed — it was still paid for" do
      entries = [
        entry(:assistant, usage(input_tokens: 1_000, output_tokens: 100)),
        entry(:compaction),
        entry(:assistant, usage(input_tokens: 200, output_tokens: 20))
      ]

      assert %Context{spent: spent} = Context.position(entries)

      assert spent.input == 1_200
      assert spent.output == 120
      assert spent.requests == 2
    end

    test "counts cache reads separately, because they are billed differently" do
      entries = [
        entry(:assistant, usage(input_tokens: 100, cached_tokens: 5_000, output_tokens: 10))
      ]

      assert %Context{spent: %{cached: 5_000}} = Context.position(entries)
    end

    test "counts cache writes separately and keeps provider token classes additive" do
      entries = [
        entry(
          :assistant,
          usage(
            input_tokens: 32_100,
            cached_tokens: 30_000,
            cache_creation_tokens: 2_000,
            output_tokens: 50,
            input_includes_cached: "true"
          )
        )
      ]

      assert %Context{
               tokens: 32_150,
               spent: %{
                 input: 100,
                 cached: 30_000,
                 cache_write: 2_000,
                 output: 50,
                 requests: 1
               }
             } = Context.position(entries)
    end

    test "is zero rather than absent for a session that has asked nothing" do
      assert %Context{
               spent: %{input: 0, output: 0, cached: 0, cache_write: 0, requests: 0}
             } =
               Context.position([])
    end
  end

  describe "reading a usage map lemieux did not write" do
    test "a missing field is zero rather than a crash" do
      assert %Context{tokens: 0} = Context.position([entry(:assistant, %{})])
    end

    test "a field that is not a number is ignored" do
      entries = [entry(:assistant, usage(input_tokens: "lots", output_tokens: 10))]

      assert %Context{tokens: 10} = Context.position(entries)
    end
  end

  describe "whether it is time to compact" do
    test "not while the window is unknown, because there is nothing to be full of" do
      entries = [entry(:assistant, usage(input_tokens: 5_000_000, output_tokens: 0))]

      refute entries |> Context.position() |> Context.full?(0.8)
    end

    test "not below the threshold" do
      entries = [entry(:assistant, usage(input_tokens: 100_000, output_tokens: 0))]

      refute entries |> Context.position(window: 200_000) |> Context.full?(0.8)
    end

    test "yes at or above it" do
      entries = [entry(:assistant, usage(input_tokens: 170_000, output_tokens: 0))]

      assert entries |> Context.position(window: 200_000) |> Context.full?(0.8)
    end
  end

  describe "delegated spend" do
    defp child(usage), do: Entry.new(:subagent_result, %{"child_id" => "01C", "usage" => usage})

    # A child's tokens are the parent's bill and never the parent's window:
    # the child has its own transcript, and nothing it read will be in the
    # parent's next request.
    test "is read off the child result envelopes, apart from the position" do
      entries = [
        entry(:assistant, usage(input_tokens: 1_000, output_tokens: 100)),
        child(usage(input_tokens: 40_000, output_tokens: 3_000, cache_read_tokens: 500))
      ]

      context = Context.position(entries, window: 200_000)

      assert context.tokens == 1_100
      assert context.delegated == %{input: 40_000, output: 3_000, cached: 500, cache_write: 0}
      assert Context.delegated_tokens(context) == 43_500
      assert Context.cumulative(context) == 44_600
    end

    # A cancellation still writes the envelope, which is the only reason the
    # tokens a cancelled fan-out burned can be accounted for at all.
    test "counts a cancelled child, whose envelope is written like any other" do
      entries = [child(usage(input_tokens: 9_000, output_tokens: 20))]

      assert entries |> Context.position() |> Context.delegated_tokens() == 9_020
    end

    # The group result repeats the per-child usage. Folding both is how a
    # fan-out comes to cost twice what it cost.
    test "ignores the group result, which repeats what the children reported" do
      entries = [
        child(usage(input_tokens: 1_000, output_tokens: 0)),
        Entry.new(:subagent_group_result, %{"usage" => usage(input_tokens: 1_000)})
      ]

      assert entries |> Context.position() |> Context.delegated_tokens() == 1_000
    end

    test "climbs with each live child usage before any envelope is written" do
      context =
        Enum.reduce([100, 200], Context.position([]), fn tokens, context ->
          Context.with_delegated_usage(context, usage(input_tokens: tokens, output_tokens: 1))
        end)

      assert Context.delegated_tokens(context) == 302
      assert context.tokens == 0
    end

    # Hosts build this struct, and older transcripts were written before some
    # of its keys existed. A missing one is not worth crashing a status line.
    test "tolerates a spend map with a class missing" do
      context = %Context{spent: %{input: 6_000, requests: 1}}

      assert Context.cumulative(context) == 6_000
    end
  end

  describe "composition" do
    defp request(system, tools, ids),
      do: Entry.new(:request, %{"system" => system, "tools" => tools, "entry_ids" => ids})

    defp bands(segments), do: Map.new(segments, &{&1.key, &1.tokens})

    # The total is the provider's. The split across the three sent parts is
    # each one's share of the bytes that were actually handed over, so a
    # window that is mostly tool schemas says so.
    test "divides the measured input by the byte share of what was sent" do
      said = Entry.new(:user, %{"text" => String.duplicate("a", 100)})

      entries = [
        said,
        request(String.duplicate("s", 100), [%{"d" => String.duplicate("t", 200)}], [said.id]),
        entry(:assistant, usage(input_tokens: 900, output_tokens: 100))
      ]

      context = Context.position(entries, window: 2_000)
      bands = context |> Context.composition(entries) |> bands()

      # 900 measured input tokens over 405 bytes: 100 of system text, 201 of
      # tool schema (the `"d"` key counts, because the provider was sent it
      # too), and 104 of conversation. The last band takes the remainder, so
      # the three add up to the measurement rather than to 899.
      assert bands[:system] == 222
      assert bands[:tools] == 446
      assert bands[:conversation] == 232
      assert bands[:system] + bands[:tools] + bands[:conversation] == 900

      # Measured directly, not apportioned.
      assert bands[:output] == 100
      assert bands[:free] == 1_000
    end

    # A screenshot's base64 is not what it costs in context. Counted byte for
    # byte it would show as nearly the whole conversation; weighed the way
    # compaction weighs it, it is one attachment's worth.
    test "weighs an attachment as compaction does, not by its base64" do
      data = String.duplicate("A", 400_000)

      said =
        Entry.new(:user, %{
          "text" => String.duplicate("a", 100),
          "attachments" => [%{"kind" => "image", "media_type" => "image/png", "data" => data}]
        })

      entries = [
        said,
        request(String.duplicate("s", 1_000), [], [said.id]),
        entry(:assistant, usage(input_tokens: 10_000, output_tokens: 100))
      ]

      bands =
        entries |> Context.position(window: 20_000) |> Context.composition(entries) |> bands()

      # Base64 counted literally would give the conversation over 99% of the
      # 10,000 sent tokens. Weighed, the system prompt's thousand bytes remain
      # a visible share of the total.
      assert bands[:system] > 1_000
      assert bands[:conversation] < 9_000
    end

    test "tiles the window exactly, so a bar drawn from it cannot overflow" do
      said = Entry.new(:user, %{"text" => "hello"})

      entries = [
        said,
        request("system", [%{"a" => "b"}], [said.id]),
        entry(:assistant, usage(input_tokens: 731, output_tokens: 37))
      ]

      segments = entries |> Context.position(window: 5_000) |> Context.composition(entries)

      assert segments |> Enum.map(& &1.tokens) |> Enum.sum() == 5_000
      assert_in_delta segments |> Enum.map(& &1.fraction) |> Enum.sum(), 1.0, 0.000_001
    end

    # A transcript with no `:request` entry cannot be split, and inventing a
    # split would be the tokenizer this module refuses by design.
    test "collapses to one sent band when nothing recorded what was sent" do
      entries = [entry(:assistant, usage(input_tokens: 400, output_tokens: 10))]

      bands =
        entries |> Context.position(window: 1_000) |> Context.composition(entries) |> bands()

      assert bands[:sent] == 400
      assert bands[:output] == 10
      assert bands[:free] == 590
      refute Map.has_key?(bands, :system)
    end

    test "says nothing about an unmeasured window rather than drawing it empty" do
      assert Context.composition(%Context{measured?: false}, []) == []
    end

    # Without a window there is no free space to show, so the bands are
    # shares of the position instead — a model nobody published limits for
    # still gets a readable split.
    test "an unknown window has no free band and divides the position" do
      entries = [entry(:assistant, usage(input_tokens: 400, output_tokens: 100))]
      segments = entries |> Context.position() |> Context.composition(entries)

      refute Enum.any?(segments, &(&1.key == :free))
      assert_in_delta segments |> Enum.map(& &1.fraction) |> Enum.sum(), 1.0, 0.000_001
    end
  end

  describe "what a compaction moves the position to" do
    # The first number is the measurement taken before the compaction entry
    # lands. The second cannot be a measurement — the position goes unmeasured
    # until the next response — so it is apportioned the same way the bands
    # are, and the caller prints it as an estimate.
    test "keeps the system prompt and the tools, and shrinks the conversation" do
      old = Entry.new(:user, %{"text" => String.duplicate("a", 300)})
      new = Entry.new(:user, %{"text" => String.duplicate("b", 100)})

      entries = [
        old,
        new,
        request(String.duplicate("s", 100), [%{"d" => String.duplicate("t", 200)}], [
          old.id,
          new.id
        ]),
        entry(:assistant, usage(input_tokens: 900, output_tokens: 100))
      ]

      context = Context.position(entries, window: 2_000)
      assert context.tokens == 1_000

      moved = Context.compacted(context, entries, [old], "a short summary")

      assert moved.before == 1_000

      # The system prompt and the tool schemas are unchanged by a compaction,
      # and the model's last answer is in the tail the cut keeps. Only the
      # conversation band moves, and it moves by the byte share the dropped
      # entry carried.
      bands = context |> Context.composition(entries) |> Map.new(&{&1.key, &1.tokens})
      assert moved.after < bands[:system] + bands[:tools] + bands[:conversation] + 100
      assert moved.after > bands[:system] + bands[:tools]
    end

    test "is silent rather than guessing when nothing recorded what was sent" do
      said = Entry.new(:user, %{"text" => "hello"})
      entries = [said, entry(:assistant, usage(input_tokens: 400, output_tokens: 10))]

      assert Context.compacted(Context.position(entries), entries, [said], "summary") == nil
    end

    # Compacting twice in a row: the second one has no measurement to start
    # from, and an entry count is the only honest thing left to say.
    test "is silent when the position was never measured" do
      assert Context.compacted(%Context{measured?: false}, [], [], "summary") == nil
    end

    # Dropping everything still leaves the system prompt, the tools and the
    # summary that replaced the conversation — never zero, and never more than
    # it started with.
    test "stays inside the position it started from" do
      said = Entry.new(:user, %{"text" => String.duplicate("a", 400)})

      entries = [
        said,
        request("system", [%{"a" => "b"}], [said.id]),
        entry(:assistant, usage(input_tokens: 900, output_tokens: 100))
      ]

      context = Context.position(entries, window: 2_000)
      moved = Context.compacted(context, entries, [said], nil)

      assert moved.after < moved.before
      assert moved.after > 0
    end
  end

  describe "status-line formatting" do
    test "uses millions and preserves a non-zero percentage below one" do
      context = %Context{
        tokens: 3_300,
        measured?: true,
        window: 1_000_000,
        fraction: 0.0033
      }

      assert Context.describe(context) == "3.3k/1.0m tokens (<1%)"
    end
  end
end
