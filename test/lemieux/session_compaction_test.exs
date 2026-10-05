defmodule Lemieux.SessionCompactionTest do
  @moduledoc """
  A session filling its window, and surviving it.

  The two tests this phase was planned around are here: that a request after a
  compaction carries the summary and not what was summarised, and that the
  transcript still holds everything that happened. The second is the one that
  keeps compaction honest — it is an entry, not a rewrite, and resume, fork and
  replay all depend on that being true.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Compaction
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_compaction_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: context.runtime,
            provider: provider,
            store: context.store,
            model: "test:model",
            subscriber: self(),
            tools: []
          ],
          opts
        )
      )

    {session, provider}
  end

  # A turn that answers with some text and reports how much of the window the
  # request took.
  defp answer(text, input_tokens) do
    [
      {:text_delta, text},
      {:usage, %{"input_tokens" => input_tokens, "output_tokens" => 0}},
      {:done, :stop}
    ]
  end

  # Four turns that leave the window comfortable, and a fourth answer that
  # fills it — so compaction is due for the fifth prompt exactly, and not
  # before. The transcript is nine entries by then, which is the first point
  # there is a turn boundary to cut at.
  defp four_roomy_turns do
    [answer("ok", 1_000), answer("ok", 1_000), answer("ok", 1_000), answer("ok", 9_000)]
  end

  defp say(session, text) do
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, _id, {:finished, _reason}}
  end

  test "disabling auto-compaction skips the threshold but keeps manual compact available",
       context do
    script = four_roomy_turns() ++ [answer("fifth", 9_000), answer("Summary", 1_000)]

    {session, provider} =
      start_session(context, script,
        context_window: 10_000,
        compact_at: 0.8,
        auto_compaction: false
      )

    for n <- 1..5, do: say(session, "prompt #{n}")

    assert length(Scripted.requests(provider)) == 5
    refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    assert {:ok, _compacted} = Session.compact(session)
    assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
  end

  test "compaction consumes the same request allowance as ordinary turns", context do
    metadata = {:response_metadata, %{status: 200, headers: %{"x-id" => ["summary-response"]}}}

    script =
      four_roomy_turns() ++ [[metadata | answer("Summary", 1_000)], answer("must not run", 1_000)]

    {session, provider} =
      start_session(context, script, context_window: 10_000, compact_at: 0.8, max_requests: 5)

    for n <- 1..4, do: say(session, "prompt #{n}")
    id = Session.id(session)
    :ok = Session.prompt(session, "prompt 5")
    assert_receive {:lemieux, ^id, {:compacted, _}}

    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests, spent: 5, cap: 5}}}}

    assert length(Scripted.requests(provider)) == 5
    requests = Enum.filter(Session.snapshot(session).entries, &(&1.type == :request))
    assert List.last(requests).payload["kind"] == "compaction"
    assert_receive {:lemieux, ^id, {:response_metadata, response}}
    assert response.request_id == List.last(requests).payload["id"]
    assert response.headers == %{"x-id" => ["summary-response"]}

    refute JSON.encode!(Enum.map(Session.snapshot(session).entries, & &1.payload)) =~
             "summary-response"
  end

  describe "where a session stands" do
    test "is reported in its snapshot, once the model has answered once", context do
      {session, _provider} = start_session(context, [answer("hi", 4_000)], context_window: 10_000)

      assert %{context: %{measured?: false, tokens: 0}} = Session.snapshot(session)

      say(session, "hello")

      assert %{context: position} = Session.snapshot(session)
      assert position.tokens == 4_000
      assert position.window == 10_000
      assert_in_delta position.fraction, 0.4, 0.001
      assert position.spent.requests == 1
    end

    test "the window is asked of the provider when nobody supplies one", context do
      # The scripted provider does not implement the callback, which is the
      # honest answer for a double: it has no model database.
      {session, _provider} = start_session(context, [answer("hi", 4_000)])

      say(session, "hello")

      assert %{context: %{window: nil, fraction: nil}} = Session.snapshot(session)
    end
  end

  describe "filling the window" do
    test "host advice can arrive during a turn and is used at the next safe boundary", context do
      owner = self()

      fourth = fn _request ->
        send(owner, {:provider_started, self()})

        receive do
          :release -> answer("ok", 1_000)
        end
      end

      script =
        for(_ <- 1..3, do: answer("ok", 1_000)) ++
          [fourth] ++
          [[{:text_delta, "Summary"}, {:done, :stop}], answer("after", 1_000)]

      hook = fn request, _context ->
        {:ok, %{request | context: Map.put(request.context, "compaction_scope", "route-a")}}
      end

      {session, provider} =
        start_session(context, script, compact_at: nil, hooks: [prepare_next_turn: hook])

      for n <- 1..3, do: say(session, "prompt #{n}")

      assert :ok == Session.prompt(session, "prompt 4")
      assert_receive {:provider_started, provider_task}

      expiry = DateTime.add(DateTime.utc_now(), 60, :second)

      assert :ok ==
               Session.advise_compaction(session, %{
                 model: "test:model",
                 reason: :logical,
                 expires_at: expiry,
                 scope: "route-a"
               })

      send(provider_task, :release)
      assert_receive {:lemieux, _id, {:finished, _reason}}
      say(session, "prompt 5")

      assert Enum.at(Scripted.requests(provider), 4).system =~ "summarising"
      assert List.last(Scripted.requests(provider)).system =~ "Summary"
      assert_receive {:lemieux, _id, {:compacted, %{trigger: :advice}}}
    end

    test "stale or mismatched host advice does not compact", context do
      script = for _ <- 1..5, do: answer("ok", 1_000)
      {session, provider} = start_session(context, script, compact_at: nil)
      for n <- 1..4, do: say(session, "prompt #{n}")

      assert {:error, :invalid_advice} ==
               Session.advise_compaction(session, %{
                 model: "test:model",
                 reason: :cost,
                 expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
               })

      assert :ok ==
               Session.advise_compaction(session, %{
                 model: "other:model",
                 reason: :cost,
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
               })

      say(session, "prompt 5")
      assert length(Scripted.requests(provider)) == 5
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "an old route scope cannot trigger compaction on a new route", context do
      script = for _ <- 1..5, do: answer("ok", 1_000)
      {session, provider} = start_session(context, script, compact_at: nil)
      for n <- 1..4, do: say(session, "prompt #{n}")

      assert :ok ==
               Session.advise_compaction(session, %{
                 model: "test:model",
                 reason: :cost,
                 expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
                 scope: "old-route"
               })

      say(session, "prompt 5")
      assert length(Scripted.requests(provider)) == 5
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "price cliff can compact before the window threshold", context do
      tiers = [
        %{up_to: 200_000, input_per_million: 2.0, output_per_million: 12.0},
        %{up_to: nil, input_per_million: 4.0, output_per_million: 18.0}
      ]

      counter = fn request ->
        prompts = Enum.count(request.entries, &(&1.type == :user))
        {:ok, if(prompts >= 5, do: 201_000, else: 1_000)}
      end

      script =
        for(_ <- 1..4, do: answer("ok", 1_000)) ++
          [
            [
              {:text_delta, "Summary"},
              {:usage, %{"input_tokens" => 100_000, "output_tokens" => 100, "cost_usd" => 0.25}},
              {:done, :stop}
            ],
            answer("after", 1_000)
          ]

      {session, provider} =
        start_session(context, script,
          context_window: 1_000_000,
          compact_at: nil,
          input_token_counter: counter,
          compaction_price_tiers: %{"test:model" => tiers}
        )

      for _n <- 1..4, do: say(session, String.duplicate("a", 100_000))
      say(session, "prompt 5")

      assert Enum.at(Scripted.requests(provider), 4).system =~ "summarising"
      assert List.last(Scripted.requests(provider)).system =~ "Summary"

      assert_receive {:lemieux, _id,
                      {:compaction_planned, %{trigger: :price, forecast: forecast}}}

      assert forecast.projected_savings_usd > 0
      assert_receive {:lemieux, _id, {:compacted, %{trigger: :price, usage: usage}}}
      assert usage["cost_usd"] == 0.25
    end

    test "preflights the final hook request before dispatch", context do
      hook = fn request, _context ->
        prompts = Enum.count(request.entries, &(&1.type == :user))

        if prompts >= 5 do
          {:ok, %{request | system: "#{request.system}\n" <> String.duplicate("x", 35_000)}}
        else
          {:ok, request}
        end
      end

      script =
        for(_ <- 1..4, do: answer("ok", 1_000)) ++
          [[{:text_delta, "Summary"}, {:done, :stop}], answer("after", 1_000)]

      {session, provider} =
        start_session(context, script,
          context_window: 10_000,
          compact_at: 0.8,
          hooks: [prepare_next_turn: hook]
        )

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      assert Enum.at(Scripted.requests(provider), 4).system =~ "summarising"
      assert Enum.at(Scripted.requests(provider), 5).system =~ "Summary"
    end

    # Every request leaves a snapshot entry holding the whole system prompt and
    # tool catalog. The provider never sends those, so they must not count
    # toward the forecast that decides when to compact: counted, twelve
    # one-word turns over a real catalog "filled" a 40k window.
    test "earlier request snapshots do not count toward the window", context do
      script = for _n <- 1..12, do: answer("ok", 1_000)

      {session, provider} =
        start_session(context, script,
          context_window: 40_000,
          compact_at: 0.8,
          tools: Lemieux.Tools.default(),
          cwd: context.tmp_dir
        )

      for n <- 1..12, do: say(session, "prompt #{n}")

      assert length(Scripted.requests(provider)) == 12
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "does nothing while there is room", context do
      script = for _n <- 1..4, do: answer("ok", 1_000)

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")

      assert length(Scripted.requests(provider)) == 4
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "compacts, and the next request carries the summary and not what was summarised",
         context do
      # Four ordinary turns, then a summarisation, then the fifth turn.
      script =
        four_roomy_turns() ++
          [
            [{:text_delta, "They said hello four times."}, {:done, :stop}],
            answer("carrying on", 1_000)
          ]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")

      id = Session.id(session)
      :ok = Session.prompt(session, "prompt 5")
      assert_receive {:lemieux, ^id, {:compacted, compacted}}
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      requests = Scripted.requests(provider)
      assert length(requests) == 6

      summarising = Enum.at(requests, 4)
      after_compaction = List.last(requests)

      # The summariser was given the elder conversation and no tools: it is
      # writing, not working.
      assert summarising.tools == []
      assert summarising.system =~ "summarising"

      assert after_compaction.system =~ "They said hello four times."
      refute after_compaction.system =~ "summarising"

      sent = Enum.map(after_compaction.entries, & &1.id)

      for cut <- compacted.entries do
        refute cut in sent
      end

      # Fewer than the uncut conversation would have sent: everything up to the
      # fourth answer, and the fifth prompt.
      semantic_entries = Enum.reject(after_compaction.entries, &(&1.type == :request))
      uncut = Enum.reject(Enum.at(requests, 3).entries, &(&1.type == :request))
      assert length(semantic_entries) < length(uncut) + 2
      assert compacted.entries != []
    end

    # Measured before the compaction entry lands, because that is the last
    # moment it can be measured: the entry makes the position unmeasured until
    # the next response, so a front end cannot work this out for itself.
    test "reports where the window was and roughly where the cut leaves it", context do
      script =
        four_roomy_turns() ++
          [
            [{:text_delta, "They said hello four times."}, {:done, :stop}],
            answer("carrying on", 1_000)
          ]

      {session, _provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")

      id = Session.id(session)
      :ok = Session.prompt(session, "prompt 5")
      assert_receive {:lemieux, ^id, {:compacted, compacted}}
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      assert %{before: before, after: remaining} = compacted.tokens

      # The fourth answer is the one that fills the window, and the position
      # is that request's rather than the sum of the four.
      assert before == 9_000
      assert remaining < before
      assert remaining > 0
    end

    test "asked for sections, the summariser is told and what it wrote is recorded", context do
      structured =
        "They said hello.\n\n## Open work\n- ship it\n\n## Dependencies\nnone\n\n" <>
          "## Decisions\n- opt in\n\n## Verification debt\n- suite not run"

      script =
        four_roomy_turns() ++
          [[{:text_delta, structured}, {:done, :stop}], answer("carrying on", 1_000)]

      {session, provider} =
        start_session(context, script,
          context_window: 10_000,
          compact_at: 0.8,
          summary_sections: true
        )

      for n <- 1..4, do: say(session, "prompt #{n}")

      id = Session.id(session)
      :ok = Session.prompt(session, "prompt 5")
      assert_receive {:lemieux, ^id, {:compacted, compacted}}
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      assert compacted.sections == %{
               open_work: ["ship it"],
               dependencies: [],
               decisions: ["opt in"],
               verification_debt: ["suite not run"]
             }

      summarising = Enum.at(Scripted.requests(provider), 4)
      assert summarising.system =~ "## Verification debt"

      assert {:ok, entries} = Store.read(context.store, id)
      assert [%Entry{payload: payload}] = Enum.filter(entries, &(&1.type == :compaction))

      assert payload["sections"] == %{
               "open_work" => ["ship it"],
               "dependencies" => [],
               "decisions" => ["opt in"],
               "verification_debt" => ["suite not run"]
             }

      # The option is part of the recorded harness, so an evidence reader can
      # tell a structured run from a prose one.
      harness = entries |> Enum.filter(&(&1.type == :harness_snapshot)) |> List.last()
      assert get_in(harness.payload, ["compaction", "summary_sections"]) == true
    end

    test "not asked for, the summariser is not told and nothing is read back", context do
      script =
        four_roomy_turns() ++
          [
            [{:text_delta, "## Decisions\n- looks structured"}, {:done, :stop}],
            answer("on", 1_000)
          ]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")

      id = Session.id(session)
      :ok = Session.prompt(session, "prompt 5")
      assert_receive {:lemieux, ^id, {:compacted, %{sections: nil}}}
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      refute Enum.at(Scripted.requests(provider), 4).system =~ "## Open work"

      assert {:ok, entries} = Store.read(context.store, id)

      assert [%Entry{payload: %{"sections" => nil}}] =
               Enum.filter(entries, &(&1.type == :compaction))
    end

    test "the transcript still holds everything that happened", context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, "a summary"}, {:done, :stop}], answer("carrying on", 1_000)]

      {session, _provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      assert {:ok, entries} = Store.read(context.store, Session.id(session))

      # Every prompt is still there — compaction appended, it did not rewrite.
      texts = for %Entry{type: :user, payload: %{"text" => text}} <- entries, do: text
      assert texts == ["prompt 1", "prompt 2", "prompt 3", "prompt 4", "prompt 5"]

      assert [%Entry{payload: payload}] = Enum.filter(entries, &(&1.type == :compaction))
      assert payload["summary"] == "a summary"
      assert payload["entries"] > 0
      assert payload["to"]
    end

    test "the tail that keeps being sent begins at a turn boundary", context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, "a summary"}, {:done, :stop}], answer("carrying on", 1_000)]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      after_compaction = List.last(Scripted.requests(provider))

      assert %Entry{type: :user} = List.first(after_compaction.entries)
    end

    test "a session whose window nobody knows, and no fallback, keeps going", context do
      script = for _n <- 1..4, do: answer("ok", 900_000)

      {session, provider} =
        start_session(context, script, compact_at: 0.8, context_window_fallback: nil)

      for n <- 1..4, do: say(session, "prompt #{n}")

      # Four prompts, four requests: no summarisation happened in between.
      assert length(Scripted.requests(provider)) == 4
    end

    # An unknown window used to mean no automatic compaction at all, so a model
    # a catalog had not heard of yet ran until the provider refused it.
    test "a session whose window nobody knows compacts against the fallback, and says so",
         context do
      script =
        [answer("ok", 1_000), answer("ok", 1_000), answer("ok", 1_000), answer("ok", 90_000)] ++
          [
            [{:text_delta, "They said hello four times."}, {:done, :stop}],
            answer("carrying on", 1_000)
          ]

      {session, provider} =
        start_session(context, script, compact_at: 0.8, context_window_fallback: 100_000)

      # Said with the first request rather than at start, which reached no
      # screen: `Lemieux.Session.Window` says why.
      say(session, "prompt 1")

      assert_received {:lemieux, _id,
                       {:context_window_unknown, %{model: "test:model", fallback: 100_000}}}

      for n <- 2..5, do: say(session, "prompt #{n}")

      assert Enum.at(Scripted.requests(provider), 4).system =~ "summarising"
      assert Session.info(session).context_window_known? == false
    end
  end

  describe "when summarising fails" do
    test "a paid failed summary remains in transcript spend", context do
      script =
        four_roomy_turns() ++
          [
            [
              {:text_delta, "partial"},
              {:usage, %{"input_tokens" => 100, "output_tokens" => 5, "cost_usd" => 0.01}},
              {:done, :length}
            ],
            answer("carrying on", 1_000)
          ]

      {session, _provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      assert %Entry{usage: %{"cost_usd" => 0.01}, payload: %{"reason" => "compaction failed"}} =
               Session.snapshot(session).entries
               |> Enum.find(&(&1.type == :error and &1.payload["reason"] == "compaction failed"))
    end

    test "a failed summary with unknown usage stays unknown in the transcript", context do
      priced_answer =
        Scripted.complete("ok",
          usage: %{"input_tokens" => 1_000, "output_tokens" => 10, "cost_usd" => 0.01}
        )

      filling_answer =
        Scripted.complete("ok",
          usage: %{"input_tokens" => 9_000, "output_tokens" => 10, "cost_usd" => 0.01}
        )

      script =
        for(_ <- 1..3, do: priced_answer) ++
          [filling_answer] ++
          [[{:text_delta, "partial"}, {:done, :length}], priced_answer]

      {session, _provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      assert_in_delta Session.snapshot(session).spent_usd, 0.04, 0.000001
      say(session, "prompt 5")

      assert Session.snapshot(session).spent_usd == nil

      assert %Entry{usage: nil} =
               Enum.find(Session.snapshot(session).entries, fn entry ->
                 entry.type == :error and entry.payload["reason"] == "compaction failed"
               end)
    end

    test "length-limited or nonterminal summaries never cut the transcript", context do
      for suffix <- [[{:done, :length}], []] do
        script =
          four_roomy_turns() ++
            [[{:text_delta, "partial"} | suffix], answer("carrying on", 1_000)]

        {session, provider} =
          start_session(context, script, context_window: 10_000, compact_at: 0.8)

        for n <- 1..4, do: say(session, "prompt #{n}")
        say(session, "prompt 5")

        assert length(Scripted.requests(provider)) == 6
        refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
      end
    end

    test "summary output is bounded and can use a separate model", context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, String.duplicate("x", 30)}, {:done, :stop}], answer("after", 1_000)]

      {session, provider} =
        start_session(context, script,
          context_window: 10_000,
          compact_at: 0.8,
          summary_model: "test:cheap",
          summary_params: [temperature: 0.0],
          summary_max_bytes: 20
        )

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      summarising = Enum.at(Scripted.requests(provider), 4)
      assert summarising.model == "test:cheap"
      assert summarising.params[:temperature] == 0.0
      # A summary gets room to be written: 4,096 tokens used to go to reasoning.
      assert summarising.params[:max_tokens] == 8_192
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "the conversation is not lost, and the turn happens anyway", context do
      script =
        four_roomy_turns() ++
          [[{:error, "the summariser is down"}], answer("carrying on", 9_500)]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      requests = Scripted.requests(provider)
      last = List.last(requests)

      # No compaction entry was written, so nothing was cut...
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
      # ...and the conversation still went to the model whole.
      assert Enum.any?(last.entries, &(&1.payload["text"] == "prompt 1"))
      assert Enum.any?(last.entries, &(&1.payload["text"] == "prompt 5"))
    end

    test "it is not attempted again on every turn after that", context do
      script =
        four_roomy_turns() ++
          [
            [{:error, "the summariser is down"}],
            answer("carrying on", 9_500),
            answer("still going", 9_500)
          ]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")
      say(session, "prompt 6")

      # Seven would mean it tried to summarise again before prompt 6, paying
      # for a doomed request in front of every turn for the rest of the session.
      assert length(Scripted.requests(provider)) == 7
    end
  end

  describe "typed provider context recovery" do
    test "does not recover by compaction when automatic triggers are disabled", context do
      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [Scripted.context_limit()]

      {session, provider} =
        start_session(context, script, compact_at: nil, auto_compaction: false)

      for n <- 1..4, do: say(session, "prompt #{n}")

      assert length(Scripted.requests(provider)) == 4
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
      refute_receive {:lemieux, _id, {:context_recovery, _payload}}
    end

    test "forces one compaction and retries when the provider rejects a pre-output request",
         context do
      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [
            Scripted.context_limit(),
            Scripted.complete("summary"),
            Scripted.complete("recovered")
          ]

      {session, provider} = start_session(context, script, compact_at: nil)

      for n <- 1..3, do: say(session, "prompt #{n}")

      id = Session.id(session)
      :ok = Session.prompt(session, "prompt 4")

      assert_receive {:lemieux, ^id,
                      {:context_recovery, %{action: :compact_and_retry, reason: reason}}}

      assert %ReqLLM.Error.API.Request{provider_code: "context_length_exceeded"} = reason
      assert_receive {:lemieux, ^id, {:compacted, _payload}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert length(Scripted.requests(provider)) == 6
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :error))

      retry_request = List.last(Scripted.requests(provider))
      assert retry_request.system =~ "summary"
    end

    test "does not retry after any provider output", context do
      context_error = Scripted.context_limit() |> List.first()

      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [[{:text_delta, "partial"}, context_error]]

      {session, provider} = start_session(context, script, compact_at: nil)

      for n <- 1..3, do: say(session, "prompt #{n}")
      say(session, "prompt 4")

      assert length(Scripted.requests(provider)) == 4
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
      assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :error))
    end

    test "usage metadata alone does not make an otherwise safe retry partial", context do
      context_error = Scripted.context_limit() |> List.first()

      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [
            [
              {:usage, %{"input_tokens" => 400, "output_tokens" => 0}},
              context_error
            ],
            Scripted.complete("summary"),
            Scripted.complete("recovered")
          ]

      {session, provider} = start_session(context, script, compact_at: nil)

      for n <- 1..3, do: say(session, "prompt #{n}")
      say(session, "prompt 4")

      assert length(Scripted.requests(provider)) == 6
      assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :error))
    end

    test "does not loop when the retry is still too large", context do
      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [
            Scripted.context_limit("first overflow"),
            Scripted.complete("summary"),
            Scripted.context_limit("still too large")
          ]

      {session, provider} = start_session(context, script, compact_at: nil)

      for n <- 1..3, do: say(session, "prompt #{n}")
      say(session, "prompt 4")

      assert length(Scripted.requests(provider)) == 6

      assert length(Enum.filter(Session.snapshot(session).entries, &(&1.type == :compaction))) ==
               1

      assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :error))
    end

    test "surfaces the original overflow when its forced compaction fails", context do
      script =
        [answer("one", 100), answer("two", 100), answer("three", 100)] ++
          [
            Scripted.context_limit("too large"),
            Scripted.error("summariser unavailable")
          ]

      {session, provider} = start_session(context, script, compact_at: nil)

      for n <- 1..3, do: say(session, "prompt #{n}")
      say(session, "prompt 4")

      assert length(Scripted.requests(provider)) == 5
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))

      assert %Entry{payload: %{"reason" => reason}} =
               Session.snapshot(session).entries
               |> Enum.filter(&(&1.type == :error))
               |> List.last()

      assert reason == "too large"
    end
  end

  describe "asking for it explicitly" do
    test "compacts a session that is nowhere near full", context do
      script =
        for(_n <- 1..4, do: answer("ok", 10)) ++
          [[{:text_delta, "a summary"}, {:done, :stop}]]

      {session, _provider} = start_session(context, script, context_window: 1_000_000)

      for n <- 1..4, do: say(session, "prompt #{n}")

      assert {:ok, compacted} = Session.compact(session)
      assert compacted.summary == "a summary"

      assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "a conversation too short to be worth cutting says so rather than pretending",
         context do
      {session, _provider} = start_session(context, [answer("ok", 10)])

      say(session, "hello")

      assert {:error, :nothing_to_do} = Session.compact(session)
    end

    test "is refused while the session is busy", context do
      {session, _provider} =
        start_session(context, [[{:text_delta, "thinking"}, {:done, :stop}]])

      :ok = Session.prompt(session, "hello")

      # Racy by nature; either answer is correct, and neither may be a crash.
      assert Session.compact(session) in [{:error, :busy}, {:error, :nothing_to_do}]
    end
  end

  describe "clearing" do
    test "stops the conversation being sent, without a summary standing in for it",
         context do
      {session, provider} =
        start_session(context, [answer("first", 10), answer("second", 10)])

      say(session, "remember this")

      # The finished turn published one; the one that matters is the next.
      assert_receive {:lemieux, _id, {:context, _measured}}

      assert {:ok, %{entries: cleared}} = Session.clear(session)
      assert cleared > 0
      assert_receive {:lemieux, _id, {:cleared, %{entries: ^cleared}}}

      # A cut makes the position unmeasured, and that is exactly what a status
      # line exists to show. Without this the screen said it had cleared the
      # conversation while the footer went on reporting the window it had just
      # emptied, until the next turn ended and corrected it.
      assert_receive {:lemieux, _id, {:context, position}}
      refute position.measured?
      assert position.tokens == 0

      say(session, "and now?")

      assert %Request{entries: entries, system: system} = List.last(Scripted.requests(provider))
      assert Enum.map(entries, & &1.payload["text"]) == ["and now?"]
      refute system =~ "earlier-conversation"
    end

    # The difference between clearing the context and destroying the session:
    # everything said is still on disk, which is what `lmx log`, a fork and a
    # replay are reads over.
    test "leaves the transcript whole", context do
      {session, _provider} = start_session(context, [answer("first", 10)])

      say(session, "remember this")
      assert {:ok, _cleared} = Session.clear(session)

      entries = Session.snapshot(session).entries

      assert Enum.any?(entries, &(&1.type == :user and &1.payload["text"] == "remember this"))
      assert Enum.any?(entries, &(&1.type == :compaction))
      assert {:ok, stored} = Store.read(context.store, Session.id(session))
      assert length(stored) == length(entries)
    end

    test "clearing twice does not resurrect the first cut", context do
      {session, provider} =
        start_session(context, [answer("first", 10), answer("second", 10), answer("third", 10)])

      say(session, "one")
      assert {:ok, _first} = Session.clear(session)
      say(session, "two")
      assert {:ok, _second} = Session.clear(session)
      say(session, "three")

      assert %Request{entries: entries} = List.last(Scripted.requests(provider))
      assert Enum.map(entries, & &1.payload["text"]) == ["three"]
    end

    test "a context with nothing in it says so rather than appending a cut", context do
      {session, _provider} = start_session(context, [])

      assert {:error, :nothing_to_do} = Session.clear(session)
      refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :compaction))
    end

    test "is refused while the session is busy", context do
      test_pid = self()

      turn = fn _request ->
        send(test_pid, {:provider_started, self()})

        receive do
          :finish -> [{:text_delta, "thinking"}, {:done, :stop}]
        end
      end

      {session, _provider} =
        start_session(context, [turn])

      :ok = Session.prompt(session, "hello")
      assert_receive {:provider_started, provider_task}

      assert {:error, :busy} = Session.clear(session)

      send(provider_task, :finish)
      assert_receive {:lemieux, _id, {:finished, :stop}}
    end
  end

  describe "a resumed session" do
    test "sends the summary and the tail, exactly as the live one did", context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, "a summary"}, {:done, :stop}], answer("carrying on", 1_000)]

      {session, provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      id = Session.id(session)
      live = List.last(Scripted.requests(provider))

      :ok =
        DynamicSupervisor.terminate_child(
          Lemieux.Supervisor.session_supervisor(context.runtime),
          session
        )

      LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

      resumed_provider = Scripted.new([answer("resumed", 1_000)])

      {:ok, resumed} =
        Lemieux.resume_session(
          supervisor: context.runtime,
          provider: resumed_provider,
          store: context.store,
          subscriber: self(),
          resume: id
        )

      :ok = Session.prompt(resumed, "prompt 6")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      [resumed_request] = Scripted.requests(resumed_provider)

      # The same cut, the same summary, from the same transcript — which is
      # what makes "resume continues exactly where it left off" checkable.
      assert resumed_request.system == live.system

      assert Enum.map(resumed_request.entries, & &1.id) |> Enum.take(length(live.entries)) ==
               Enum.map(live.entries, & &1.id)
    end
  end

  describe "the summary in front of a request" do
    test "is what Compaction.with_summary builds, not something the session invented",
         context do
      script =
        four_roomy_turns() ++
          [[{:text_delta, "a summary"}, {:done, :stop}], answer("carrying on", 1_000)]

      {session, provider} =
        start_session(context, script,
          context_window: 10_000,
          compact_at: 0.8,
          system: "be brief"
        )

      for n <- 1..4, do: say(session, "prompt #{n}")
      say(session, "prompt 5")

      assert %Request{system: system} = List.last(Scripted.requests(provider))

      assert system == Compaction.with_summary("be brief", "a summary")
    end
  end

  describe "a host's own compaction" do
    # Changes what the summariser is asked and how the summary is framed, and
    # leaves the cut to the default — the shape the module documentation
    # recommends. Its state is the tone, to prove the pair form reaches it.
    defmodule Terse do
      @moduledoc false
      @behaviour Lemieux.Compaction

      @impl true
      def instructions(tone, previous, opts) do
        "Summarise the earlier conversation #{tone}." <>
          if(Keyword.get(opts, :sections), do: " Use sections.", else: "") <>
          if(previous, do: " Earlier summary: #{previous}", else: "")
      end

      @impl true
      def with_summary(_tone, system, nil), do: system
      def with_summary(_tone, system, summary), do: "#{system}\n\n[earlier: #{summary}]"

      @impl true
      defdelegate plan(state, entries, opts), to: Compaction
      @impl true
      defdelegate applied(state, entries, opts), to: Compaction
      @impl true
      defdelegate conversation?(state, entries), to: Compaction
      @impl true
      defdelegate summary(state, entries), to: Compaction
      @impl true
      defdelegate sections(state, summary), to: Compaction
    end

    # Reports the options its plan was asked with to the test, which is its
    # state.
    defmodule Recording do
      @moduledoc false
      @behaviour Lemieux.Compaction

      @impl true
      def plan(test, entries, opts) do
        send(test, {:planned, opts})
        Compaction.plan(entries, opts)
      end

      @impl true
      defdelegate applied(state, entries, opts), to: Compaction
      @impl true
      defdelegate conversation?(state, entries), to: Compaction
      @impl true
      defdelegate summary(state, entries), to: Compaction
      @impl true
      defdelegate sections(state, summary), to: Compaction
      @impl true
      defdelegate instructions(state, previous, opts), to: Compaction
      @impl true
      defdelegate with_summary(state, system, summary), to: Compaction
    end

    test "its summariser instructions reach the provider, state and all", context do
      script =
        for(_n <- 1..4, do: answer("ok", 10)) ++
          [[{:text_delta, "they said hello"}, {:done, :stop}], answer("ok", 10)]

      {session, provider} =
        start_session(context, script,
          context_window: 1_000_000,
          compaction: {Terse, "in one line"}
        )

      for n <- 1..4, do: say(session, "prompt #{n}")

      assert {:ok, %{summary: "they said hello"}} = Session.compact(session)

      summarising = provider |> Scripted.requests() |> Enum.at(4)
      assert summarising.system == "Summarise the earlier conversation in one line."
      assert summarising.tools == []

      # The framing of the summary in the next request is the host's too.
      say(session, "prompt 5")
      after_compaction = List.last(Scripted.requests(provider))
      assert after_compaction.system =~ "[earlier: they said hello]"
      refute after_compaction.system =~ "<earlier-conversation>"

      # What was written is the same entry whichever module summarised.
      assert [%Entry{payload: %{"summary" => "they said hello", "entries" => cut}}] =
               Enum.filter(Session.snapshot(session).entries, &(&1.type == :compaction))

      assert cut > 0
    end

    test "the session's own options still reach it", context do
      script =
        for(_n <- 1..4, do: answer("ok", 10)) ++ [[{:text_delta, "brief"}, {:done, :stop}]]

      {session, provider} =
        start_session(context, script,
          context_window: 1_000_000,
          summary_sections: true,
          compaction: {Terse, "briefly"}
        )

      for n <- 1..4, do: say(session, "prompt #{n}")
      assert {:ok, _compacted} = Session.compact(session)

      assert %Request{system: "Summarise the earlier conversation briefly. Use sections."} =
               List.last(Scripted.requests(provider))
    end

    # The keep defaults live in `Lemieux.Compaction.plan/2` and nowhere else; a
    # session that was not told otherwise asks for nothing — it passes the capped
    # window as information — so a replacement is free to choose its own.
    test "the keep fraction reaches the plan only when a host set it", context do
      script = for(_n <- 1..4, do: answer("ok", 10)) ++ [[{:text_delta, "s"}, {:done, :stop}]]

      {session, _provider} =
        start_session(context, script, context_window: 1_000_000, compaction: {Recording, self()})

      for n <- 1..4, do: say(session, "prompt #{n}")
      assert {:ok, _compacted} = Session.compact(session)
      assert_receive {:planned, [window: 200_000]}

      {session, _provider} =
        start_session(context, script,
          context_window: 1_000_000,
          compaction: {Recording, self()},
          keep: 0.5
        )

      for n <- 1..4, do: say(session, "prompt #{n}")
      assert {:ok, _compacted} = Session.compact(session)
      assert_receive {:planned, [keep: 0.5, window: 200_000]}
    end

    test "nothing about the module reaches the transcript", context do
      {session, _provider} =
        start_session(context, [answer("ok", 10)], compaction: {Terse, "tersely"})

      say(session, "hello")

      assert %Entry{payload: config} =
               Enum.find(Session.snapshot(session).entries, &(&1.type == :session))

      refute Map.has_key?(config, "compaction")
      refute inspect(config) =~ "Terse"
    end

    test "something that is neither a module nor a pair is refused at start", context do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Lemieux.start_session(
                 supervisor: context.runtime,
                 provider: Scripted.new([]),
                 store: context.store,
                 model: "test:model",
                 compaction: "terse"
               )

      assert message =~ ":compaction"
    end
  end
end
