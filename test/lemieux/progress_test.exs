defmodule Lemieux.ProgressTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Progress
  alias Lemieux.Progress.Evidence
  alias Lemieux.Progress.Verdict
  alias Lemieux.Providers.Scripted

  defp result(name, arguments, output, seq, opts \\ []) do
    Entry.new(
      :tool_result,
      %{
        "name" => name,
        "arguments" => arguments,
        "output" => output,
        "error" => Keyword.get(opts, :error, false),
        "call_id" => "call-#{seq}"
      },
      seq: seq,
      at: Keyword.get(opts, :at, DateTime.utc_now())
    )
  end

  defp request(seq, at), do: Entry.new(:request, %{}, seq: seq, at: at)

  defp read(path, seq, opts \\ []),
    do: result("read", %{"path" => path}, "contents of #{path}", seq, opts)

  describe "the transcript rules" do
    test "distinct calls are inconclusive, and settle as progress when nobody is asked" do
      entries = for {path, seq} <- Enum.with_index(~w(a b c d e f g)), do: read(path, seq)

      verdict =
        entries |> Progress.evidence(interval_ms: 1_000) |> Progress.assess(assess: :activity)

      assert %Verdict{outcome: :progressing, by: :activity} = verdict
      assert verdict.note =~ "7 distinct calls"
    end

    # The session's own rule needs the *same* round three times running.
    # `a, b, a, b, a, b` never gives it that, and is what a weaker model
    # actually does.
    test "an alternating loop is a stall, decided without a model" do
      entries = for {path, seq} <- Enum.with_index(~w(a b a b a b a b)), do: read(path, seq)

      verdict =
        entries
        |> Progress.evidence(interval_ms: 1_000)
        |> Progress.assess(assess: fn _evidence -> flunk("the rules should have decided") end)

      assert %Verdict{outcome: :stalled, by: :activity} = verdict

      assert verdict.note ==
               "6 of the last 8 calls repeated an earlier call and got the same answer"
    end

    test "asking again after the answer changed is not a repeat" do
      # A test re-run after every edit, failing differently each time.
      entries =
        Enum.map(0..7, fn seq ->
          if rem(seq, 2) == 0,
            do: result("edit", %{"path" => "lib/x.ex", "n" => seq}, "edited", seq),
            else: result("bash", %{"command" => "mix test"}, "failure #{seq}", seq)
        end)

      refute entries
             |> Progress.evidence()
             |> Progress.assess(assess: :activity)
             |> Map.get(:outcome) ==
               :stalled
    end

    test "fewer than six calls are never enough to call a loop" do
      entries = for {path, seq} <- Enum.with_index(~w(a b a b a)), do: read(path, seq)

      refute Progress.repeating?(Enum.map(entries, & &1.payload))

      assert %Verdict{outcome: :progressing} =
               entries |> Progress.evidence() |> Progress.assess(assess: :activity)
    end

    test "a quiet interval with a request in flight is waiting, not stuck" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -90, :second)
      entries = [read("a", 1, at: earlier), request(2, earlier)]

      evidence = Progress.evidence(entries, since_seq: 2, interval_ms: 60_000, now: now)

      assert evidence.entries == []
      assert %{kind: :request, since_ms: since} = evidence.in_flight
      assert_in_delta since, 90_000, 1_000

      verdict = Progress.assess(evidence, assess: fn _ -> flunk("nobody should be asked") end)
      assert %Verdict{outcome: :progressing, by: :activity} = verdict
      assert verdict.note =~ "waiting on a provider request for 1m 30s"
    end

    test "a quiet interval with a tool in flight names the tool" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -1_200, :second)

      entries = [
        Entry.new(
          :assistant,
          %{
            "content" => [],
            "tool_calls" => [
              %{"id" => "c1", "name" => "bash", "arguments" => %{"command" => "mix test"}}
            ]
          },
          seq: 5,
          at: earlier
        )
      ]

      verdict =
        entries
        |> Progress.evidence(since_seq: 5, interval_ms: 120_000, now: now)
        |> Progress.assess(assess: :activity)

      assert %Verdict{
               outcome: :progressing,
               by: :activity,
               note: "waiting on the bash tool for 20m"
             } =
               verdict
    end

    test "a quiet interval with nothing in flight is a stall" do
      entries = [Entry.new(:cancelled, %{"reason" => "x"}, seq: 9)]

      verdict =
        entries |> Progress.evidence(since_seq: 9, interval_ms: 120_000) |> Progress.assess()

      assert %Verdict{outcome: :stalled, by: :activity, note: "nothing happened for 2m"} = verdict
    end

    test "only entries after the last check count as the interval's activity" do
      entries = for {path, seq} <- Enum.with_index(~w(a b a b a b a b c d)), do: read(path, seq)

      # All ten: the alternation dominates. From the ninth on: two distinct.
      assert %Verdict{outcome: :stalled} =
               entries |> Progress.evidence() |> Progress.assess(assess: :activity)

      evidence = Progress.evidence(entries, since_seq: 7)
      assert length(evidence.calls) == 2
      assert evidence.last_seq == 9
      assert %Verdict{outcome: :progressing} = Progress.assess(evidence, assess: :activity)
    end
  end

  describe "the judge" do
    defp inconclusive do
      entries = for {path, seq} <- Enum.with_index(~w(a b c d e f)), do: read(path, seq)

      Progress.evidence(entries,
        elapsed_ms: 250_000,
        interval_ms: 120_000,
        checks: 1,
        subject: %{
          kind: :subagent,
          id: "child-1",
          definition_id: "scout",
          objective: "Find the bug"
        }
      )
    end

    defp answering(text, opts \\ []) do
      Scripted.new([Scripted.complete(text, usage: Keyword.get(opts, :usage))],
        estimated_cost_usd: 0.0
      )
    end

    test "is shown the objective, the clocks and the interval's calls" do
      text = Progress.describe(inconclusive())

      assert text =~ "Objective: Find the bug"
      assert text =~ "Elapsed: 4m 10s; this is check 2, each covering 2m."
      assert text =~ "Calls in this interval (oldest first), all 6:"
      assert text =~ ~s(1. read {"path":"a"} → contents of a)
      assert text =~ ~s(6. read {"path":"f"} → contents of f)
    end

    test "shows the tail of a long interval and says what it left out" do
      entries = for seq <- 1..40, do: read("file-#{seq}", seq)
      text = entries |> Progress.evidence() |> Progress.describe()

      assert text =~ "the last 24 of 40 (16 earlier omitted):"
      refute text =~ ~s({"path":"file-16"})
      assert text =~ ~s({"path":"file-17"})
    end

    test "a structured stall verdict cancels, with the model's reason and its usage" do
      provider =
        answering(
          ~s({"verdict":"stalled","reason":"It keeps opening files it has already read."}),
          usage: %{"input_tokens" => 40, "output_tokens" => 12, "cost_usd" => 0.002}
        )

      verdict = Progress.assess(inconclusive(), provider: provider, model: "test:judge")

      assert %Verdict{outcome: :stalled, by: :model} = verdict
      assert verdict.note == "It keeps opening files it has already read."
      assert verdict.usage["cost_usd"] == 0.002

      [request] = Scripted.requests(provider)
      assert request.model == "test:judge"
      assert request.system =~ ~s(Prefer "progressing" when unsure)
      assert [%Entry{type: :user, payload: %{"text" => text}}] = request.entries
      assert text =~ "Objective: Find the bug"
    end

    test "a fenced or worded answer is still read" do
      fenced =
        answering(~s(```json\n{"verdict": "progressing", "reason": "new files"}\n```))

      assert %Verdict{outcome: :progressing, note: "new files"} =
               Progress.assess(inconclusive(), provider: fenced, model: "m")

      worded = answering("I think it is stalled, honestly.")

      assert %Verdict{outcome: :stalled, by: :model} =
               Progress.assess(inconclusive(), provider: worded, model: "m")
    end

    # On a manual clock the allowance ends exactly when the test says: a
    # millisecond short of it the question is still open, and at it the
    # verdict falls open. The judge never answers on its own.
    test "a judge's timeout is measured on the clock it is given" do
      clock = Manual.new()

      silent =
        Scripted.new([fn _request -> receive do: (:never -> :ok) end], estimated_cost_usd: 0.0)

      checking =
        Task.async(fn ->
          Progress.assess(inconclusive(),
            provider: silent,
            model: "m",
            timeout_ms: 50,
            clock: clock
          )
        end)

      assert %{due_in: 50} = Manual.await_timer(clock, &match?({:judge_timeout, _}, &1.message))

      Manual.advance(clock, 49)
      assert Task.yield(checking, 0) == nil

      Manual.advance(clock, 1)
      assert %Verdict{outcome: :progressing, by: :error} = verdict = Task.await(checking)
      assert verdict.note =~ "judge_timeout"
    end

    # The two mistakes are not symmetric: an unanswered question must not
    # kill a child that may be working. The hard deadline still bounds it.
    test "a judge that fails, times out or answers nonsense falls open" do
      failing = Scripted.new([Scripted.error("the judge is down")], estimated_cost_usd: 0.0)
      verdict = Progress.assess(inconclusive(), provider: failing, model: "m")
      assert %Verdict{outcome: :progressing, by: :error} = verdict
      assert verdict.note =~ "6 distinct calls"
      assert verdict.note =~ "fell open"

      slow =
        Scripted.new([Scripted.delayed(5_000, Scripted.complete("late"))],
          estimated_cost_usd: 0.0
        )

      # The real-time check of the judge's timeout: a judge that answers in
      # five seconds against a 50 ms allowance, so only the outcome is asserted.
      verdict = Progress.assess(inconclusive(), provider: slow, model: "m", timeout_ms: 50)
      assert %Verdict{outcome: :progressing, by: :error} = verdict
      assert verdict.note =~ "judge_timeout"

      raising =
        Scripted.new([fn _request -> raise "the judge exploded" end], estimated_cost_usd: 0.0)

      verdict = Progress.assess(inconclusive(), provider: raising, model: "m")
      assert %Verdict{outcome: :progressing, by: :error} = verdict
      assert verdict.note =~ "judge_raised"

      nonsense = answering("both progressing and stalled, who can say")

      assert %Verdict{outcome: :progressing, by: :error} =
               Progress.assess(inconclusive(), provider: nonsense, model: "m")

      unconfigured = Progress.assess(inconclusive(), assess: :model)
      assert %Verdict{outcome: :progressing, by: :error} = unconfigured
      assert unconfigured.note =~ "missing_option"
    end

    test "a host assessor answers in any of the accepted shapes" do
      evidence = inconclusive()

      assert %Verdict{outcome: :stalled, by: :host, note: "no"} =
               Progress.assess(evidence, assess: fn _ -> {:stalled, "no"} end)

      assert %Verdict{outcome: :progressing, by: :host} =
               Progress.assess(evidence, assess: fn _ -> :progressing end)

      assert %Verdict{outcome: :stalled, by: :host, note: "mine"} =
               Progress.assess(evidence,
                 assess: fn _ -> %Verdict{outcome: :stalled, by: :model, note: "mine"} end
               )

      assert %Verdict{outcome: :progressing, by: :error} =
               Progress.assess(evidence, assess: fn _ -> :maybe end)
    end
  end

  test "the evidence is what a check needs and nothing that is not in the transcript" do
    evidence = Progress.evidence([], subject: %{objective: "x"})

    assert %Evidence{entries: [], calls: [], in_flight: nil, last_seq: nil, turns: 0} = evidence
  end
end
