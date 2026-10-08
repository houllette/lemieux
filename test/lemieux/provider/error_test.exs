defmodule Lemieux.Provider.ErrorTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider.Error
  alias ReqLLM.Error.API.Request, as: RequestError
  alias ReqLLM.Error.API.Stream, as: StreamError
  alias ReqLLM.Error.API.Timeout, as: TimeoutError

  test "keeps classification separate from presentation" do
    error =
      RequestError.exception(
        reason: "request is too large",
        status: 400,
        provider_code: "context_length_exceeded"
      )

    assert Error.category(error) == :context_limit
    assert Error.context_limit?(error)
    assert Error.message(error) == "request is too large"
    assert Error.http_status(error) == 400
  end

  test "does not guess context overflow from human prose" do
    error =
      RequestError.exception(reason: "maximum context length exceeded", status: 400)

    refute Error.context_limit?(error)
    assert Error.category(error) == :other
  end

  test "extracts retry-after without discarding the original error" do
    error =
      RequestError.exception(
        reason: "slow down",
        status: 429,
        headers: %{"retry-after" => ["1.5"]}
      )

    assert Error.category(error) == :rate_limit
    assert Error.retryable?(error)
    assert Error.retry_after_ms(error) == 1_500
  end

  test "follows a stream wrapper to its typed cause" do
    cause = RequestError.exception(reason: "busy", status: 503)
    wrapper = StreamError.exception(reason: "stream failed", cause: cause)

    assert Error.category(wrapper) == :server
    assert Error.retryable?(wrapper)
    assert Error.message(wrapper) == "busy"
  end

  test "classifies a stream that stalled mid-answer as a timeout, however it is wrapped" do
    # The shape req_llm actually produces: StreamServer answers its consumer
    # `{:error, :timeout}` and the lazy stream wraps the bare atom as :cause.
    assert Error.category(
             StreamError.exception(reason: "Stream failed: :timeout", cause: :timeout)
           ) ==
             :timeout

    # Finch and Mint carry it as :reason instead.
    assert Error.category(%Mint.TransportError{reason: :timeout}) == :timeout

    # And the typed exception, when the transport does raise one.
    assert Error.category(TimeoutError.exception(kind: :stream_idle, timeout: 30_000)) == :timeout

    # A stream that failed for a reason that is not a stall is not a timeout.
    assert Error.category(StreamError.exception(reason: "Stream failed: :badarg", cause: :badarg)) ==
             :other
  end

  test "an HTTP 408 is a timeout, as retryable?/1 already said" do
    # A CDN in front of a gateway answered seven streaming requests in one
    # benchmark with a bare 408 and an empty body. `retryable?/1` counted it;
    # `category/1` filed it under :other, so a host retrying by category
    # recorded each one as the model failing.
    timed_out = RequestError.exception(reason: "HTTP 408", status: 408, response_body: "")

    assert Error.category(timed_out) == :timeout
    assert Error.retryable?(timed_out)
    assert Error.transient?(timed_out)
    assert Error.http_status(timed_out) == 408

    # Wrapped by a stream, the same.
    assert Error.category(StreamError.exception(reason: "Stream failed", cause: timed_out)) ==
             :timeout

    # Other 4xx statuses are still what they were: a refusal, retryable or not.
    assert Error.category(RequestError.exception(reason: "HTTP 414", status: 414)) == :other
    assert Error.category(RequestError.exception(reason: "HTTP 409", status: 409)) == :other
  end

  test "classifies a dropped connection as the provider failing, not refusing" do
    # A refusal arrives with a status and a body. A connection the far end
    # closed mid-answer — a load balancer's reset, a gateway restarting — is the
    # provider failing, like a 5xx, and worth asking again.
    for dropped <- [
          StreamError.exception(reason: "Stream failed: :closed", cause: :closed),
          %Mint.TransportError{reason: :closed},
          %Mint.TransportError{reason: :econnreset},
          StreamError.exception(
            reason: "Stream failed",
            cause: %Mint.TransportError{reason: :econnaborted}
          )
        ] do
      assert Error.category(dropped) == :server
      assert Error.transient?(dropped)
    end

    # A connection refused before anything was sent is somebody not listening,
    # not a dropped answer.
    assert Error.category(%Mint.TransportError{reason: :econnrefused}) == :other
  end

  test "a stream that carried nothing and ended :incomplete is the provider failing, not refusing" do
    # A gateway behind a CDN answered 200 and closed the stream with no delta,
    # no tool call, no usage and no finish reason. That is the interrupted
    # stream one step earlier — cut before the first token — and a host that
    # retries :server, :timeout and :rate_limit recorded it as the model
    # failing while it was :other.
    for finish <- [:incomplete, :unknown] do
      cut = {:unanswered, "ixway:gpt-6-luna", finish}

      assert Error.category(cut) == :server
      assert Error.transient?(cut)
      assert Error.retryable?(cut)
      assert Error.http_status(cut) == nil
      assert Error.message(cut) =~ "answered nothing at all"
      assert Error.message(cut) =~ "cut off before the first token"
    end

    # A provider that finished on purpose and said so is not a cut stream. (A
    # filtered answer is a refusal: see "a refusal on policy grounds".)
    for finish <- [:length, :content_filter] do
      ended = {:unanswered, "openai:gpt-5", finish}

      refute Error.category(ended) == :server
      refute Error.transient?(ended)
      refute Error.retryable?(ended)
    end
  end

  # The ChatGPT Codex backend refused a benchmark task with `cyber_policy`, and
  # the session recorded a crash in `:other` (#32). A host could not tell a
  # refusal from a bug in an adapter, and a refusal retried is one more flagged
  # request on the account.
  describe "a refusal on policy grounds" do
    test "is :refused by its code, wherever the failure carries it, and never retried" do
      refusals = [
        RequestError.exception(reason: "flagged", status: 400, provider_code: "cyber_policy"),
        RequestError.exception(
          reason: "flagged",
          status: 400,
          response_body: ~s({"error":{"code":"invalid_prompt","type":"invalid_request_error"}})
        ),
        RequestError.exception(
          reason: "filtered",
          status: 400,
          response_body: %{"error" => %{"code" => "Content_Filter"}}
        ),
        StreamError.exception(
          reason: "stream failed",
          cause:
            RequestError.exception(
              reason: "policy",
              status: 400,
              provider_code: "content_policy_violation"
            )
        ),
        %Lemieux.Provider.Interrupted{
          provider: "openai",
          detail: "flagged",
          code: "cyber_policy"
        },
        # Anthropic's `refusal` stop reason, with nothing said before it.
        {:unanswered, "anthropic:claude-sonnet-5", :content_filter}
      ]

      for refusal <- refusals do
        assert Error.category(refusal) == :refused, inspect(refusal)
        refute Error.transient?(refusal), inspect(refusal)
        refute Error.retryable?(refusal), inspect(refusal)
        refute Error.account?(refusal), inspect(refusal)
      end
    end

    test "is not read from prose, and a cut answer is still the provider failing" do
      prose = RequestError.exception(reason: "cyber_policy: content blocked", status: 400)

      assert Error.category(prose) == :other
      assert Error.category({:unanswered, "openai:gpt-5", :length}) == :other

      # An interrupted stream's other codes classify as they would anywhere.
      overflow = %Lemieux.Provider.Interrupted{code: "context_length_exceeded"}
      assert Error.category(overflow) == :context_limit

      assert Error.category(%Lemieux.Provider.Interrupted{code: "rate_limit_exceeded"}) ==
               :rate_limit
    end

    test "names the provider's code in its message" do
      refusal = %Lemieux.Provider.Interrupted{
        provider: "openai_codex",
        finish_reason: :error,
        detail: "This request was flagged.",
        code: "cyber_policy"
      }

      assert Error.message(refusal) =~ "cyber_policy"
      assert Error.message(refusal) =~ "This request was flagged."
    end
  end

  describe "code/1" do
    test "is the provider's own code, from a typed field, a body or a stream's error event" do
      assert Error.code(RequestError.exception(reason: "x", status: 400, provider_code: "a_b")) ==
               "a_b"

      assert Error.code(%Lemieux.Provider.Interrupted{code: "cyber_policy"}) == "cyber_policy"

      # A body's nested error says more than its top-level `type`, which for
      # Anthropic is the word "error".
      anthropic =
        RequestError.exception(
          reason: "Overloaded",
          status: 529,
          response_body: %{"type" => "error", "error" => %{"type" => "overloaded_error"}}
        )

      assert Error.code(anthropic) == "overloaded_error"

      codex =
        RequestError.exception(
          reason: "flagged",
          status: 400,
          response_body: ~s({"error":{"code":"cyber_policy","type":"invalid_request"}})
        )

      assert Error.code(codex) == "cyber_policy"
      assert Error.code(StreamError.exception(reason: "wrapped", cause: codex)) == "cyber_policy"
      assert Error.code({:context_limit, codex}) == "cyber_policy"
    end

    test "is nil when the failure carries none" do
      assert Error.code(RequestError.exception(reason: "HTTP 408", status: 408)) == nil
      assert Error.code(:timeout) == nil
      assert Error.code("cyber_policy") == nil
      assert Error.code(%Lemieux.Provider.Interrupted{detail: "overloaded"}) == nil
    end
  end

  # req_llm 1.26's `openai_codex` provider raises a stream's `error` event
  # inside its stream server (agentjido/req_llm#1079), which takes the
  # provider task down with it. That is the provider answering, not a bug.
  describe "recognize_crash/1" do
    defp codex_crash(message),
      do:
        {%RuntimeError{message: message},
         [{ReqLLM.Providers.OpenAICodex, :normalize_stream_event!, 1, [line: 505]}]}

    test "reads a Codex stream error event out of the crash it caused" do
      event =
        JSON.encode!(%{
          "type" => "error",
          "error" => %{
            "code" => "cyber_policy",
            "type" => "invalid_request",
            "message" => "This request was flagged."
          }
        })

      for crash <- [
            codex_crash("Codex error: " <> event),
            # Seen by a consumer whose call to the stream server failed.
            {codex_crash("Codex error: " <> event), {GenServer, :call, [:server, :next, 5_000]}}
          ] do
        assert %Lemieux.Provider.Interrupted{
                 provider: "openai_codex",
                 finish_reason: :error,
                 code: "cyber_policy",
                 detail: "This request was flagged."
               } = refusal = Error.recognize_crash(crash)

        assert Error.category(refusal) == :refused
        refute Error.transient?(refusal)
      end
    end

    test "keeps the sentence of an event that carried no code, as the provider failing" do
      assert %Lemieux.Provider.Interrupted{code: nil, detail: "upstream overloaded"} =
               interrupted =
               Error.recognize_crash(codex_crash("Codex error: upstream overloaded"))

      assert Error.category(interrupted) == :server

      assert %Lemieux.Provider.Interrupted{detail: "Codex response failed"} =
               Error.recognize_crash(codex_crash("Codex response failed"))
    end

    test "leaves every other crash a crash" do
      elsewhere =
        {%RuntimeError{message: "Codex error: {}"}, [{SomeAdapter, :decode, 1, []}]}

      called = {elsewhere, {GenServer, :call, [:server, :next, 5_000]}}

      for reason <- [elsewhere, called, :killed, {%ArgumentError{}, []}, {:shutdown, :normal}] do
        assert Error.recognize_crash(reason) == {:provider_crashed, reason}
      end
    end
  end

  test "an interrupted stream is a retryable server failure with the provider's sentence" do
    interrupted = %Lemieux.Provider.Interrupted{provider: "openai", detail: "upstream overloaded"}

    assert Error.category(interrupted) == :server
    assert Error.transient?(interrupted)
    assert Error.retryable?(interrupted)
    assert Error.http_status(interrupted) == nil

    assert Error.message(interrupted) ==
             "the provider ended the stream before the answer was complete: upstream overloaded"

    assert Error.message(%Lemieux.Provider.Interrupted{provider: "anthropic"}) ==
             "the provider ended the stream before the answer was complete"
  end

  describe "an overflow a provider gives no code" do
    # Anthropic and Gemini refuse an oversized prompt with a generic 400 whose
    # only mark is their own sentence. Recognised for the provider the request
    # went to, with the status it uses — never read out of just any failure.
    @anthropic "prompt is too long: 213462 tokens > 200000 maximum"
    @gemini "The input token count (1234567) exceeds the maximum number of tokens allowed (1048576)."

    defp refusal(message, status \\ 400, provider_code \\ nil) do
      RequestError.exception(
        reason: message,
        status: status,
        provider_code: provider_code,
        response_body: %{"type" => provider_code, "message" => message}
      )
    end

    test "is recognised for the provider that says it, and states the window" do
      anthropic =
        Error.recognize_overflow(refusal(@anthropic, 400, "invalid_request_error"), "anthropic")

      assert Error.context_limit?(anthropic)
      assert Error.category(anthropic) == :context_limit
      assert Error.stated_context_window(anthropic) == 200_000
      assert Error.message(anthropic) == @anthropic
      assert Error.http_status(anthropic) == 400
      refute Error.transient?(anthropic)

      gemini = Error.recognize_overflow(refusal(@gemini), "google")

      assert Error.context_limit?(gemini)
      assert Error.stated_context_window(gemini) == 1_048_576

      # Claude served through a cloud keeps Anthropic's sentence.
      assert Error.context_limit?(Error.recognize_overflow(refusal(@anthropic), "google_vertex"))

      assert Error.context_limit?(
               Error.recognize_overflow(
                 refusal("Input is too long for requested model."),
                 "amazon_bedrock"
               )
             )
    end

    test "is not recognised from another provider, another status, or no provider" do
      # The same sentence from a provider that does not use it is prose.
      refute Error.context_limit?(Error.recognize_overflow(refusal(@anthropic), "openai"))
      # A 500 carrying it is a server failure, whatever it says.
      refute Error.context_limit?(Error.recognize_overflow(refusal(@anthropic, 500), "anthropic"))
      # A failure nobody attributed to a provider stays unknown.
      refute Error.context_limit?(Error.recognize_overflow(refusal(@anthropic), nil))
      # And a sentence that only resembles one does not count.
      refute Error.context_limit?(
               Error.recognize_overflow(refusal("the prompt is fine"), "anthropic")
             )
    end

    test "OpenAI-compatible servers are recognised by their own sentences" do
      for {provider, sentence, window} <- [
            {"deepseek",
             "This model's maximum context length is 65536 tokens. However, you requested 70000 tokens.",
             65_536},
            {"openrouter",
             "This endpoint's maximum context length is 131072 tokens. However, you requested about 140000 tokens.",
             131_072},
            {"xai",
             "This model's maximum prompt length is 131072 but the request contains 135000 tokens.",
             131_072},
            {"mistral",
             "Prompt contains 32781 tokens and 0 draft tokens, too large for model with 32768 maximum context length",
             32_768}
          ] do
        reason = Error.recognize_overflow(refusal(sentence), provider)

        assert Error.context_limit?(reason), provider
        assert Error.stated_context_window(reason) == window, provider
      end
    end

    test "Z.AI's numeric code is read for Z.AI only" do
      body = %{"error" => %{"code" => "1261", "message" => "Prompt exceeds max length"}}

      zai =
        RequestError.exception(
          reason: "Prompt exceeds max length",
          status: 400,
          response_body: body
        )

      assert Error.context_limit?(Error.recognize_overflow(zai, "zai_coding_plan"))
      refute Error.context_limit?(Error.recognize_overflow(zai, "openai"))
    end

    test "a coded overflow needs no recognition, and a recognised one is not wrapped twice" do
      coded =
        RequestError.exception(
          reason: "This model's maximum context length is 128000 tokens.",
          status: 400,
          provider_code: "context_length_exceeded"
        )

      assert Error.recognize_overflow(coded, "openai") == coded
      assert Error.stated_context_window(coded) == 128_000

      marked = Error.recognize_overflow(refusal(@anthropic), "anthropic")
      assert Error.recognize_overflow(marked, "anthropic") == marked
    end

    test "a window is never read from a failure that is not an overflow" do
      refute Error.stated_context_window(refusal("rate limited: 5000 maximum", 429))
      refute Error.stated_context_window(refusal(@anthropic))
    end

    test "follows a stream wrapper to the refusal inside it" do
      wrapped =
        StreamError.exception(
          reason: "Stream failed",
          cause: refusal(@anthropic, 400, "invalid_request_error")
        )

      recognized = Error.recognize_overflow(wrapped, "anthropic")

      assert Error.context_limit?(recognized)
      assert Error.stated_context_window(recognized) == 200_000
      assert Error.http_status(recognized) == 400
    end
  end

  # A session on 2026-09-18 ended on eleven kilobytes of a gateway's debug
  # page — stylesheet first, the one line that mattered buried in it — as the
  # error on screen and in the transcript. A message is for a person.
  describe "an HTML body" do
    @page """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>CompileError</title>
    <style>html{font-family:sans-serif} .heading-block{padding:48px}</style>
    <script>window.x = 1;</script></head>
    <body><div class="heading-block"><h1>CompileError</h1>
    <p>Compilation error</p><p>Console output is shown below.</p>
    <pre>error: undefined function interrupted_hint/1
    lib/ixway_web/live/waste_live.ex:259</pre>
    </div></body></html>
    """

    test "is reduced to its title and its first lines of text" do
      message = Error.message(RequestError.exception(reason: @page, status: 500))

      assert message =~ ~s(the provider answered with an HTML page titled "CompileError")
      assert message =~ "Compilation error"
      assert message =~ "undefined function interrupted_hint/1"
      assert message =~ "lib/ixway_web/live/waste_live.ex:259"
      refute message =~ "<style"
      refute message =~ "font-family"
      refute message =~ "window.x"
      assert byte_size(message) < 600
    end

    test "is still classified by its status, not its prose" do
      assert Error.category(RequestError.exception(reason: @page, status: 500)) == :server
      assert Error.category(RequestError.exception(reason: @page, status: 400)) == :other
    end
  end

  test "any message is cut at two kilobytes and says how much is missing" do
    long = String.duplicate("x", 5_000)
    message = Error.message(RequestError.exception(reason: long, status: 500))

    assert byte_size(message) < 2_100
    assert message =~ "3000 more bytes"
  end

  # The sentences for a gateway's failures live with the gateway, on a typed
  # error that describes itself. A bare tag has no owner here, so it is shown
  # as the data it is rather than guessed at from its name.
  test "an untyped vendor tuple is shown as data, not projected into prose" do
    assert Error.message({:ixway, :api_key_required}) == inspect({:ixway, :api_key_required})
  end

  describe "transient?/2" do
    test "without a classifier it is today's rule: server, rate limit, timeout, or a retryable flag" do
      assert Error.transient?(RequestError.exception(reason: "busy", status: 503))
      assert Error.transient?(RequestError.exception(reason: "slow down", status: 429))

      assert Error.transient?(
               StreamError.exception(reason: "Stream failed: :timeout", cause: :timeout)
             )

      assert Error.transient?(%{retryable: true})

      refute Error.transient?(RequestError.exception(reason: "bad request", status: 400))
      refute Error.transient?({:missing_api_key, :anthropic, "set ANTHROPIC_API_KEY"})
    end

    test "a classifier's verdict wins in either direction, and :default falls through" do
      bad_request = RequestError.exception(reason: "bad request", status: 400)
      busy = RequestError.exception(reason: "busy", status: 503)

      assert Error.transient?(bad_request, fn _reason -> :transient end)
      refute Error.transient?(busy, fn _reason -> :fatal end)

      assert Error.transient?(busy, fn _reason -> :default end)
      refute Error.transient?(bad_request, fn _reason -> :default end)
    end

    test "the classifier sees the original reason, untouched" do
      reason = RequestError.exception(reason: "busy", status: 503)
      parent = self()

      Error.transient?(reason, fn seen ->
        send(parent, {:classified, seen})
        :default
      end)

      assert_receive {:classified, ^reason}
    end

    test "a classifier that answers anything else is a bug, and is named as one" do
      assert_raise ArgumentError, ~r/:transient, :fatal or :default/, fn ->
        Error.transient?(:boom, fn _reason -> :maybe end)
      end
    end
  end

  describe "account?/1" do
    test "an authentication, payment or permission status is about the account" do
      for status <- [401, 402, 403] do
        assert Error.account?(RequestError.exception(reason: "no", status: status))
      end

      refute Error.account?(RequestError.exception(reason: "busy", status: 503))
      refute Error.account?(RequestError.exception(reason: "bad request", status: 400))
    end

    # OpenAI answers an exhausted quota with a 429, which the rate-limit rule
    # would otherwise wait out as though capacity were coming back.
    test "a spent quota behind a 429 is read from the typed code" do
      quota =
        RequestError.exception(
          reason: "You exceeded your current quota",
          status: 429,
          provider_code: "insufficient_quota"
        )

      assert Error.account?(quota)
      refute Error.account?(RequestError.exception(reason: "slow down", status: 429))
    end

    test "a code or type in the response body counts, nested or not, cause included" do
      typed_body =
        RequestError.exception(
          reason: "quota",
          status: 429,
          response_body: %{"error" => %{"type" => "billing_not_active"}}
        )

      encoded_body =
        RequestError.exception(
          reason: "key",
          status: 400,
          response_body: ~s({"error":{"code":"Invalid_API_Key "}})
        )

      wrapped = StreamError.exception(reason: "stream failed", cause: typed_body)

      assert Error.account?(typed_body)
      assert Error.account?(encoded_body)
      assert Error.account?(wrapped)
      assert Error.account?({:context_limit, typed_body})
    end

    test "prose that mentions a key or a quota is not a code" do
      refute Error.account?(
               RequestError.exception(reason: "invalid_api_key: check your key", status: 400)
             )

      refute Error.account?(:timeout)
      refute Error.account?("insufficient_quota")
    end
  end
end
