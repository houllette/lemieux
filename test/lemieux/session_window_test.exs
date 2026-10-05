defmodule Lemieux.SessionWindowTest do
  @moduledoc """
  What a session knows about its model's window, what it tells a person
  about it, and what it does when the window leaves no room.

  The window a local model is served with is a server setting the server
  only reports once the model is loaded, and a server that drops what does
  not fit instead of refusing it. These tests stand in for one with the
  scripted provider's `{:context_window, tokens}` event.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Compaction
  alias Lemieux.Prompt
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_window_#{System.unique_integer([:positive])}"
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
            tools: [],
            cwd: context.tmp_dir
          ],
          opts
        )
      )

    {session, provider}
  end

  defp answer(text, input_tokens, extra \\ []) do
    [{:text_delta, text}, {:usage, %{"input_tokens" => input_tokens, "output_tokens" => 1}}] ++
      extra ++ [{:done, :stop}]
  end

  defp say(session, text) do
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, _id, {:finished, _reason}}, 5_000
  end

  defp compactions(session),
    do: Enum.count(Session.snapshot(session).entries, &(&1.type == :compaction))

  describe "a window nobody publishes" do
    # Said at start, the note reached nobody: the TUI drops what arrives
    # before it knows its session's id, and `lmx run` subscribes when it
    # sends the prompt. A subscriber that joins after start stands in for
    # both.
    test "is said with the first request, where a host that joined late hears it", context do
      {session, _provider} = start_session(context, [answer("ok", 100)], subscriber: nil)
      :ok = Session.subscribe(session, self())

      refute_received {:lemieux, _id, {:context_window_unknown, _unknown}}

      say(session, "hello")

      assert_received {:lemieux, _id,
                       {:context_window_unknown, %{model: "test:model", fallback: 128_000}}}
    end

    test "is said once, however many requests follow", context do
      {session, _provider} = start_session(context, [answer("ok", 100), answer("ok", 100)])

      say(session, "one")
      say(session, "two")

      notes = collect(fn -> receive_window_unknown() end)
      assert length(notes) == 1
    end
  end

  describe "a window too small for the session's own instructions and tools" do
    test "is called out once, with the room those take", context do
      {session, _provider} =
        start_session(context, [answer("ok", 100), answer("ok", 100)],
          context_window: 6_000,
          tools: Tools.default()
        )

      say(session, "one")
      say(session, "two")

      assert_received {:lemieux, _id,
                       {:context_window_small,
                        %{
                          model: "test:model",
                          window: 6_000,
                          overhead: overhead,
                          source: :configured
                        }}}

      # The instructions and the tools, at the four bytes a token every
      # forecast here assumes: what no compaction can cut.
      fixed = %Request{model: "test:model", system: Prompt.default(), tools: Tools.default()}
      assert overhead == div(Request.input_bytes(fixed) + 3, 4)
      refute_received {:lemieux, _id, {:context_window_small, _again}}
    end

    test "is not mentioned when there is room", context do
      {session, _provider} = start_session(context, [answer("ok", 100)], context_window: 200_000)

      say(session, "one")

      refute_received {:lemieux, _id, {:context_window_small, _small}}
    end
  end

  describe "the window a server reports serving" do
    test "replaces the fallback, is planned against, and is weighed at once", context do
      script = [answer("ok", 1_000, [{:context_window, 4_096}]), answer("ok", 1_000)]
      {session, _provider} = start_session(context, script)

      say(session, "one")

      assert_received {:lemieux, _id, {:context_window_small, %{window: 4_096, source: :served}}}

      assert %{context_window_known?: true, context: %{window: 4_096}} = Session.info(session)

      say(session, "two")
      assert_received {:lemieux, _id, {:context, %{window: 4_096}}}
    end

    test "bounds a configured window it is smaller than, and never raises one", context do
      script = [
        answer("ok", 1_000, [{:context_window, 8_192}]),
        answer("ok", 1_000, [{:context_window, 262_144}])
      ]

      {session, _provider} = start_session(context, script, context_window: 32_768)

      say(session, "one")
      assert %{context: %{window: 8_192}} = Session.info(session)

      say(session, "two")
      assert %{context: %{window: 32_768}} = Session.info(session)
    end

    test "is forgotten when the model changes", context do
      script = [answer("ok", 1_000, [{:context_window, 4_096}])]
      {session, _provider} = start_session(context, script)

      say(session, "one")
      assert %{context: %{window: 4_096}} = Session.info(session)

      assert {:ok, "test:other"} = Session.set_model(session, "test:other")
      assert %{context_window_known?: false, context: %{window: nil}} = Session.info(session)
    end
  end

  describe "a window its own instructions and tools would fill" do
    # The finding this guards: on a 4,096-token window lmx summarised, sent
    # two requests, summarised again, and so on until a request budget
    # stopped it with no answer. Its instructions and nine tools come to
    # about 3,500 tokens, over 0.8 of that window, so no summary can make
    # room. A longer system prompt brings the four default tools to the same.
    test "is never summarised on the threshold, however long the session runs", context do
      script = for _n <- 1..10, do: answer("ok", 3_900)
      system = String.duplicate("Follow the instructions. ", 400)

      {session, provider} =
        start_session(context, script,
          context_window: 4_096,
          compact_at: 0.8,
          system: system,
          tools: Tools.default()
        )

      for n <- 1..10, do: say(session, "prompt #{n}")

      assert length(Scripted.requests(provider)) == 10
      assert compactions(session) == 0
      assert_received {:lemieux, _id, {:context_window_small, %{window: 4_096}}}
    end
  end

  describe "a summary that made no room" do
    # A compaction that cuts only the first entry: what every compaction is
    # on a window the session's own instructions nearly fill, and what a
    # tail that cannot be cut makes of any other.
    defmodule KeepsEverything do
      @behaviour Lemieux.Compaction

      @impl true
      def plan(_state, [first | rest], _opts) when rest != [],
        do: {:ok, %{elder: [first], tail: rest}}

      def plan(_state, _entries, _opts), do: :nothing_to_do

      @impl true
      def applied(_state, entries, opts), do: Compaction.applied(entries, opts)
      @impl true
      def conversation?(_state, entries), do: Compaction.conversation?(entries)
      @impl true
      def summary(_state, entries), do: Compaction.summary(entries)
      @impl true
      def sections(_state, summary), do: Compaction.sections(summary)
      @impl true
      def instructions(_state, previous, opts), do: Compaction.instructions(previous, opts)
      @impl true
      def with_summary(_state, system, summary), do: Compaction.with_summary(system, summary)
    end

    test "backs the threshold off instead of summarising every other request", context do
      # Three thousand tokens a prompt: the third request crosses the
      # 8,000-token threshold, and from then on every request is over it
      # whatever is summarised.
      prompt = String.duplicate("word ", 2_400)
      script = for _n <- 1..14, do: answer("summary or answer", 100)

      {session, provider} =
        start_session(context, script,
          context_window: 10_000,
          compact_at: 0.8,
          compaction: KeepsEverything
        )

      for n <- 1..10, do: say(session, "#{n} #{prompt}")

      assert compactions(session) == 1
      assert length(Scripted.requests(provider)) == 11

      assert_received {:lemieux, _id,
                       {:compaction_ineffective,
                        %{
                          threshold: 8_000,
                          window: 10_000,
                          retry_in: retry_in,
                          input_tokens: tokens
                        }}}

      assert retry_in >= 10
      assert tokens >= 8_000
    end

    test "a summary that did make room is not called ineffective", context do
      script =
        [answer("ok", 1_000), answer("ok", 1_000), answer("ok", 1_000), answer("ok", 9_000)] ++
          [answer("a summary", 1_000), answer("carrying on", 1_000)]

      {session, _provider} =
        start_session(context, script, context_window: 10_000, compact_at: 0.8)

      for n <- 1..5, do: say(session, "prompt #{n}")

      assert compactions(session) == 1
      refute_received {:lemieux, _id, {:compaction_ineffective, _payload}}
    end
  end

  defp receive_window_unknown do
    receive do
      {:lemieux, _id, {:context_window_unknown, _unknown} = note} -> note
    after
      0 -> nil
    end
  end

  defp collect(take, acc \\ []) do
    case take.() do
      nil -> Enum.reverse(acc)
      value -> collect(take, [value | acc])
    end
  end
end
