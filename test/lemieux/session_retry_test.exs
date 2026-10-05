defmodule Lemieux.SessionRetryTest do
  @moduledoc """
  A request that fails before producing output is sent again.

  A session on 2026-09-18 lost an afternoon's tool results behind one
  gateway response — a development server's compile-error page — because
  the turn ended on it. A transient failure now costs a backoff, a
  persistent one still ends the turn, and `Session.retry/1` is the way back
  from the second.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_retry_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts \\ []) do
    provider = Scripted.new(script, estimated_cost_usd: 0.0)

    {:ok, session} =
      [
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        subscriber: self(),
        # Fast, so the tests measure the behaviour and not the backoff.
        provider_retry: [base_delay_ms: 5]
      ]
      |> Keyword.merge(opts)
      |> Lemieux.start_session()

    {session, provider}
  end

  defp gateway_down, do: Scripted.http_error(503, reason: "gateway is restarting")

  describe "retry admission and host accounting" do
    for status <- [429, 503] do
      @status status
      test "a request cap preserves HTTP #{status} without waiting or scheduling a retry",
           context do
        [{:error, reason}] = Scripted.http_error(@status, headers: %{"retry-after" => "17"})
        owner = self()

        {session, provider} =
          start_session(context, [[{:error, reason}], Scripted.complete("never sent")],
            max_requests: 1,
            hooks: [error: fn error, _context -> send(owner, {:observed_error, error}) end]
          )

        id = Session.id(session)
        :ok = Session.prompt(session, "go")

        assert_receive {:lemieux, ^id, {:error, ^reason}}
        assert_receive {:observed_error, ^reason}
        assert_receive {:lemieux, ^id, {:finished, :error}}
        refute_receive {:lemieux, ^id, {:provider_retry, _}}
        assert length(Scripted.requests(provider)) == 1

        {:ok, entries} = Store.read(context.store, id)
        assert [error] = Enum.filter(entries, &(&1.type == :error))
        assert error.payload["reason"] == ProviderError.message(reason)
        assert error.payload["category"] == Atom.to_string(ProviderError.category(reason))
        assert Session.snapshot(session).status == :idle
      end
    end

    test "a turn ceiling also refuses another provider attempt", context do
      {session, provider} =
        start_session(context, [gateway_down(), Scripted.complete("never sent")], max_turns: 1)

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:finished, :error}}
      refute_receive {:lemieux, ^id, {:provider_retry, _}}
      assert length(Scripted.requests(provider)) == 1
    end

    test "unknown spend after failure refuses backoff without losing the provider error",
         context do
      {session, provider} =
        start_session(context, [gateway_down(), Scripted.complete("never sent")],
          max_cost_usd: 1.0
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:error, reason}}
      assert ProviderError.category(reason) == :server
      assert_receive {:lemieux, ^id, {:finished, :error}}
      refute_receive {:lemieux, ^id, {:provider_retry, _}}
      assert length(Scripted.requests(provider)) == 1
    end

    test "preparation can distinguish a retry and resets for the next prompt", context do
      owner = self()

      hook = fn request, context ->
        send(owner, {:preparing, context})
        {:ok, request}
      end

      {session, provider} =
        start_session(
          context,
          [gateway_down(), Scripted.complete("done"), Scripted.complete("next")],
          max_requests: 5,
          hooks: [prepare_next_turn: hook]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:preparing, %{retry: nil}}

      assert_receive {:preparing, %{retry: %{"attempt" => 1, "category" => "server"} = retry}}

      assert_receive {:lemieux, ^id, {:finished, :stop}}
      {:ok, entries} = Store.read(context.store, id)
      [first, second] = Enum.filter(entries, &(&1.type == :request))
      assert retry == second.payload["retry"]
      assert retry["after_request_id"] == first.payload["id"]
      :ok = Session.prompt(session, "again")
      assert_receive {:preparing, %{retry: nil}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert length(Scripted.requests(provider)) == 3
    end

    test "a retry consumes the remaining request allowance", context do
      {session, provider} =
        start_session(context, [gateway_down(), gateway_down(), Scripted.complete("never sent")],
          max_requests: 2
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:provider_retry, %{attempt: 1}}}
      assert_receive {:lemieux, ^id, {:error, reason}}
      assert ProviderError.category(reason) == :server
      assert_receive {:lemieux, ^id, {:finished, :error}}
      refute_receive {:lemieux, ^id, {:provider_retry, %{attempt: 2}}}
      assert length(Scripted.requests(provider)) == 2
    end

    test "a hook changing the retry estimate cannot erase the original error", context do
      [{:error, reason}] = gateway_down()

      provider =
        Scripted.new(
          [[{:usage, %{"cost_usd" => 0.0}}, {:error, reason}], Scripted.complete("never sent")],
          estimated_cost_usd: fn request -> if request.params[:costly], do: 2.0, else: 0.0 end
        )

      hook = fn request, context ->
        {:ok, %{request | params: Keyword.put(request.params, :costly, context.retry != nil)}}
      end

      {session, _unused} =
        start_session(context, [],
          provider: provider,
          max_cost_usd: 1.0,
          hooks: [prepare_next_turn: hook]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:provider_retry, _}}
      assert_receive {:lemieux, ^id, {:error, ^reason}}
      assert_receive {:lemieux, ^id, {:finished, :error}}
      assert length(Scripted.requests(provider)) == 1
      assert Session.snapshot(session).status == :idle
      {:ok, entries} = Store.read(context.store, id)
      assert [error] = Enum.filter(entries, &(&1.type == :error))
      assert error.payload["reason"] == ProviderError.message(reason)
    end

    test "a returned error without an emitted event is preserved at the cap", context do
      [{:error, reason}] = gateway_down()

      {session, _unused} =
        start_session(context, [],
          provider: {Lemieux.SessionRetryTest.ReturnedError, reason},
          max_requests: 1
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:error, ^reason}}
      assert_receive {:lemieux, ^id, {:finished, :error}}
      refute_receive {:lemieux, ^id, {:provider_retry, _}}
    end
  end

  describe "a transient failure before any output" do
    test "response metadata remains observable without preventing retry", context do
      metadata = {:response_metadata, %{status: 503, headers: %{"x-id" => ["failed-attempt"]}}}

      {session, provider} =
        start_session(context, [[metadata | gateway_down()], Scripted.complete("done")])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:response_metadata, response}}
      assert_receive {:lemieux, ^id, {:provider_retry, _}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert length(Scripted.requests(provider)) == 2
      {:ok, entries} = Store.read(context.store, id)
      [first, _second] = Enum.filter(entries, &(&1.type == :request))
      assert response.request_id == first.payload["id"]
      refute JSON.encode!(Enum.map(entries, & &1.payload)) =~ "failed-attempt"
    end

    test "is retried, and the retried request records why", context do
      {session, provider} = start_session(context, [gateway_down(), Scripted.complete("done")])
      id = Session.id(session)

      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id, {:provider_retry, retry}}
      assert retry.attempt == 1
      # Six attempts by default: enough to ride out a couple of minutes of an
      # overloaded provider.
      assert retry.max == 6
      assert retry.category == :server
      assert retry.delay_ms == 5
      assert ProviderError.message(retry.reason) == "gateway is restarting"

      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert length(Scripted.requests(provider)) == 2

      {:ok, entries} = Store.read(context.store, id)
      # No error entry: the turn survived. The second request says what
      # it followed.
      refute Enum.any?(entries, &(&1.type == :error))
      assert [first, second] = Enum.filter(entries, &(&1.type == :request))
      refute Map.has_key?(first.payload, "retry")

      assert %{"attempt" => 1, "category" => "server", "after_request_id" => after_id} =
               second.payload["retry"]

      assert after_id == first.payload["id"]
      assert second.payload["retry"]["reason"] == "gateway is restarting"
    end

    test "honours a retry-after the provider sends over the backoff", context do
      {session, _provider} =
        start_session(context, [
          Scripted.http_error(429, headers: %{"retry-after" => "0"}),
          Scripted.complete("done")
        ])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id, {:provider_retry, %{category: :rate_limit, delay_ms: 0}}}

      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "a stream that went quiet is retried too", context do
      {session, _provider} =
        start_session(context, [Scripted.stream_timeout(), Scripted.complete("done")])

      id = Session.id(session)

      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id, {:provider_retry, %{category: :timeout}}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "ends the turn as an error once the attempts are used up", context do
      {session, provider} =
        start_session(context, List.duplicate(gateway_down(), 3),
          provider_retry: [base_delay_ms: 5, max_attempts: 2]
        )

      id = Session.id(session)

      :ok = Session.prompt(session, "go")

      # The backoff doubles: five milliseconds, then ten.
      assert_receive {:lemieux, ^id, {:provider_retry, %{attempt: 1, delay_ms: 5}}}
      assert_receive {:lemieux, ^id, {:provider_retry, %{attempt: 2, delay_ms: 10}}}
      assert_receive {:lemieux, ^id, {:error, _reason}}
      assert_receive {:lemieux, ^id, {:finished, :error}}

      assert length(Scripted.requests(provider)) == 3
      assert Session.snapshot(session).status == :idle

      {:ok, entries} = Store.read(context.store, id)
      assert [error] = Enum.filter(entries, &(&1.type == :error))
      assert error.payload["category"] == "server"
    end

    test "the count starts over once a request answers", context do
      script = [
        gateway_down(),
        Scripted.complete("first"),
        gateway_down(),
        Scripted.complete("second")
      ]

      {session, provider} = start_session(context, script)
      id = Session.id(session)

      :ok = Session.prompt(session, "one")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      :ok = Session.prompt(session, "two")
      assert_receive {:lemieux, ^id, {:provider_retry, %{attempt: 1}}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert length(Scripted.requests(provider)) == 4
    end
  end

  # Nothing a partial answer contained has run — tool calls only run once a
  # response is complete — so a stream that dies halfway is safe to ask again.
  # It used to end the turn, which in `lmx run` meant a job that failed on a
  # provider hiccup with nobody there to type `/retry`.
  describe "a failure after output has arrived" do
    test "is retried, and the partial answer is kept but never sent again", context do
      {session, provider} =
        start_session(context, [
          Scripted.interrupted("half an ans", provider: "anthropic"),
          Scripted.complete("the whole answer")
        ])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id,
                      {:provider_retry, %{attempt: 1, after_output: true, category: :server}}}

      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, second] = Scripted.requests(provider)
      refute Enum.any?(second.entries, &(&1.type == :assistant))

      {:ok, entries} = Store.read(context.store, id)
      assert [partial, answer] = Enum.filter(entries, &(&1.type == :assistant))
      assert partial.payload["partial"] == true
      assert [%{"text" => "half an ans"}] = partial.payload["content"]
      assert [%{"text" => "the whole answer"}] = answer.payload["content"]
      refute Enum.any?(entries, &(&1.type == :error))
    end

    test "a stream that keeps dying after a few words is not retried forever", context do
      cut = fn -> Scripted.interrupted("almost") end

      {session, provider} =
        start_session(context, for(_n <- 1..8, do: cut.()), provider_retry: [base_delay_ms: 1])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, ^id, {:finished, :error}}, 5_000
      # The first request and six retries: output arriving no longer resets the count.
      assert length(Scripted.requests(provider)) == 7
    end

    test "is not retried when the host kept the older rule", context do
      {session, provider} =
        start_session(
          context,
          [Scripted.interrupted("half an ans"), Scripted.complete("never sent")],
          provider_retry: [base_delay_ms: 5, after_output: false]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      refute_receive {:lemieux, ^id, {:provider_retry, _}}, 200
      assert_receive {:lemieux, ^id, {:finished, :error}}
      assert length(Scripted.requests(provider)) == 1
    end
  end

  describe "what is never retried on its own" do
    # An exhausted OpenAI quota is a 429 with its own code. Waiting it out six
    # times before saying so would cost a person minutes and change nothing.
    test "a failure of the account rather than the provider", context do
      for {status, code} <- [{429, "insufficient_quota"}, {401, nil}, {403, nil}] do
        {session, provider} =
          start_session(context, [
            Scripted.http_error(status, provider_code: code),
            Scripted.complete("never sent")
          ])

        id = Session.id(session)
        :ok = Session.prompt(session, "go")

        refute_receive {:lemieux, ^id, {:provider_retry, _}}, 100
        assert_receive {:lemieux, ^id, {:finished, :error}}
        assert length(Scripted.requests(provider)) == 1
      end
    end

    test "a failure the provider will repeat", context do
      {session, provider} =
        start_session(context, [
          [{:error, {:missing_api_key, :anthropic, "SET_ME"}}],
          Scripted.complete("never sent")
        ])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      refute_receive {:lemieux, ^id, {:provider_retry, _}}, 200
      assert_receive {:lemieux, ^id, {:finished, :error}}
      assert length(Scripted.requests(provider)) == 1
    end

    test "anything, when the host turned retries off", context do
      {session, provider} =
        start_session(context, [gateway_down(), Scripted.complete("never sent")],
          provider_retry: false
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")

      refute_receive {:lemieux, ^id, {:provider_retry, _}}, 200
      assert_receive {:lemieux, ^id, {:finished, :error}}
      assert length(Scripted.requests(provider)) == 1
    end
  end

  test "cancelling during the backoff stops the retry", context do
    # A backoff far longer than the suite's five-second wait for an event, so
    # only the cancel can end this turn before the waits below give up. At
    # five seconds, a cancel that took effect only once the backoff ran out
    # could still have landed inside that wait.
    {session, provider} =
      start_session(context, [gateway_down(), Scripted.complete("never sent")],
        provider_retry: [base_delay_ms: :timer.minutes(1)]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")

    # The request that failed, so the refutation below is about the retry.
    assert_receive {:lemieux, ^id, {:entry, %{type: :request}}}
    assert_receive {:lemieux, ^id, {:provider_retry, _}}
    assert Session.snapshot(session).status == :busy

    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}
    refute_receive {:lemieux, ^id, {:entry, %{type: :request}}}, 200
    assert length(Scripted.requests(provider)) == 1
    assert Session.snapshot(session).status == :idle
  end

  describe "retry/1" do
    test "sends the failed request again with everything before it", context do
      script = [
        Scripted.tool_call("c1", "echo", %{"say" => "hi"}),
        # The failure that ends the turn: not transient, so no automatic
        # attempt hides what the manual one is for.
        [{:error, {:missing_api_key, :anthropic, "SET_ME"}}],
        Scripted.complete("carried on")
      ]

      {session, provider} = start_session(context, script, tools: [Lemieux.SessionRetryTest.Echo])
      id = Session.id(session)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:finished, :error}}

      assert :ok = Session.retry(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      # The third request carries the tool result the first turn recorded,
      # and no second user prompt.
      [_first, _failed, retried] = Scripted.requests(provider)
      assert Enum.any?(retried.entries, &(&1.type == :tool_result))
      assert Enum.count(retried.entries, &(&1.type == :user)) == 1

      {:ok, entries} = Store.read(context.store, id)
      assert Enum.any?(entries, &(&1.type == :error))

      assert %{"content" => [%{"text" => "carried on"}]} =
               List.last(Enum.filter(entries, &(&1.type == :assistant))).payload
    end

    test "is refused while a turn is running, and when nothing failed", context do
      {session, _provider} = start_session(context, [Scripted.complete("fine")])
      id = Session.id(session)

      assert {:error, :nothing_to_retry} = Session.retry(session)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert {:error, :nothing_to_retry} = Session.retry(session)
    end

    test "is refused after a turn budget or a cancellation, which a retry would not change",
         context do
      # An answer that would arrive long after the suite's wait for an event,
      # so the turn ends only because it was cancelled.
      {session, _provider} =
        start_session(context, [Scripted.delayed(:timer.minutes(1), Scripted.complete("late"))])

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert {:error, :busy} = Session.retry(session)

      :ok = Session.cancel(session)
      assert_receive {:lemieux, ^id, {:finished, :cancelled}}
      assert {:error, :nothing_to_retry} = Session.retry(session)
    end
  end

  defmodule Echo do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "echo"
    @impl Lemieux.Tool
    def description, do: "Echoes what it is given."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{"say" => %{"type" => "string"}}}
    @impl Lemieux.Tool
    def run(%{"say" => say}, _context), do: {:ok, "echo: #{say}"}
  end

  defmodule ReturnedError do
    @moduledoc false
    @behaviour Lemieux.Provider

    @impl true
    def run(reason, _request, _emit), do: {:error, reason}
  end

  # The backoff is a timer on the session's clock: with a manual one, the
  # retry waits exactly until the test moves time past its delay.
  test "a retry waits on the session's clock", context do
    clock = start_supervised!(Manual)

    {session, _provider} =
      start_session(context, [Scripted.http_error(503), Scripted.complete("recovered")],
        provider_retry: [base_delay_ms: 5_000],
        clock: clock
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:lemieux, ^id, {:provider_retry, %{attempt: 1, delay_ms: 5_000}}}
    Manual.advance(clock, 4_999, settle: session)
    refute_received {:lemieux, ^id, {:finished, _reason}}

    Manual.advance(clock, 1, settle: session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
  end
end
