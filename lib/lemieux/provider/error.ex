defmodule Lemieux.Provider.Error do
  @moduledoc """
  Policy-facing facts about a provider failure, without replacing the failure.

  `req_llm` already returns typed exceptions. Lemieux keeps those original
  values all the way through the session and uses this module only to answer
  the few questions the harness owns: what a person should see, whether the
  provider asked callers to wait, and whether an otherwise safe conversation
  needs one forced compaction.

  That distinction is load-bearing. Wrapping every provider error in another
  Lemieux exception would hide fields added upstream just as surely as turning
  it into a string did. Functions here therefore accept any term and never
  mutate it. Unknown shapes remain unknown rather than being classified from
  provider prose.

  Two exceptions to that last rule are deliberate and narrow. A provider that
  gives a context overflow no code — Anthropic, Gemini — is recognised by its
  own sentence, but only by the adapter, which knows which provider a request
  went to: see `recognize_overflow/2`. And a stream that ended before the
  answer did becomes a `Lemieux.Provider.Interrupted`, because `req_llm`
  reports two such endings as success.
  """

  alias Lemieux.Provider.Interrupted

  @context_limit_codes MapSet.new([
                         "context_length_exceeded",
                         "context_limit_exceeded",
                         "context_window_exceeded",
                         # llama.cpp's server, behind any OpenAI-compatible route.
                         "exceed_context_size_error",
                         "input_too_long",
                         "max_context_length_exceeded",
                         "prompt_too_long",
                         "request_too_large"
                       ])

  # Providers whose wire format is OpenAI's, and so whose overflow sentence is
  # OpenAI's or a close copy of it. Named rather than assumed of every provider,
  # so a new provider's errors stay unknown until somebody has seen them.
  @openai_wire_providers ~w(alibaba alibaba_cn atlascloud azure cerebras deepseek fireworks_ai
                            github_copilot groq lmstudio meta minimax mistral moonshot_ai nearai
                            ollama openai openai_codex openrouter venice vllm xai zai zai_coder
                            zai_coding_plan zenmux)

  # Z.AI answers an oversized prompt with its own numeric code rather than a
  # sentence worth matching.
  @zai_providers ~w(zai zai_coder zai_coding_plan)

  # A transport that dropped the connection mid-answer. Not a refusal: a refusal
  # arrives with a status and a body.
  @dropped_transport_reasons [:closed, :econnreset, :econnaborted, :epipe, :enetreset]

  @rate_limit_codes MapSet.new([
                      "rate_limit_exceeded",
                      "rate_limited",
                      "too_many_requests"
                    ])

  # What an account, not the request, is wrong about: a key, a permission, a
  # spent quota or an unpaid bill. Names seen from OpenAI, Anthropic and their
  # imitators, in the `code` or `type` a failure's body carries.
  @account_codes MapSet.new([
                   "authentication_error",
                   "billing_hard_limit_reached",
                   "billing_not_active",
                   "credit_balance_too_low",
                   "insufficient_quota",
                   "invalid_api_key",
                   "permission_error",
                   "quota_exceeded"
                 ])

  @typedoc "A stable policy category derived from typed fields, never error prose."
  @type category :: :context_limit | :rate_limit | :server | :timeout | :other

  # A gateway in development answers a failed request with its whole debug page —
  # eleven kilobytes of stylesheet with the one line that matters buried in it, and
  # it went into the transcript and onto the screen verbatim. A message is for a
  # person to read, so an HTML body is reduced to its title and first lines of
  # text, and anything is cut at this size.
  @max_message_bytes 2_000
  @excerpt_bytes 600

  @doc "Returns a safe human-readable projection of `reason`."
  @spec message(reason :: term()) :: String.t()
  def message(reason), do: reason |> projection() |> readable()

  # No vendor's vocabulary is projected here. A gateway's failures are typed
  # exceptions that describe themselves (`Lemieux.Ixway.Error`), rendered by
  # the exception clause below like any other; the sentences used to be a
  # clause per Ixway reason in this function, which made this module the one
  # place a second gateway would have had to edit.
  defp projection({:unknown_model, spec, reason}),
    do: "unknown model #{inspect(spec)}: #{message(reason)}"

  defp projection({:missing_api_key, _provider, hint}) when is_binary(hint), do: hint

  defp projection({:tool_schema_unsupported, _provider, _tool, _keyword, message}), do: message

  defp projection({:unanswered, model, finish_reason}) do
    "#{model} answered nothing at all and ended with #{inspect(finish_reason)} rather than a normal stop. " <>
      "The streaming interface did not carry the reason; check provider credit, quota, and request validity."
  end

  defp projection({:context_limit, reason}), do: message(reason)
  defp projection(%{cause: cause}) when not is_nil(cause), do: message(cause)
  defp projection(%{reason: reason}) when is_binary(reason), do: reason
  defp projection(%{message: value}) when is_binary(value), do: value
  defp projection(reason) when is_exception(reason), do: Exception.message(reason)
  defp projection(reason) when is_binary(reason), do: reason
  defp projection(reason), do: inspect(reason)

  defp readable(text) do
    text
    |> condense_html()
    |> clip(@max_message_bytes)
  end

  defp condense_html(text) do
    if html?(text) do
      title = title(text)
      body = text |> without(~r/<(style|script)\b.*?<\/\1>/si) |> tagless() |> String.trim()
      excerpt = body |> String.replace(title || "", "", global: false) |> String.trim()

      "the provider answered with an HTML page" <>
        if(title, do: " titled #{inspect(title)}", else: "") <>
        if(excerpt == "", do: "", else: ": " <> clip(excerpt, @excerpt_bytes))
    else
      text
    end
  end

  defp html?(text) do
    text
    |> String.trim_leading()
    |> String.slice(0, 15)
    |> String.downcase()
    |> String.starts_with?(["<!doctype", "<html"])
  end

  defp title(text) do
    case Regex.run(~r/<title>(.*?)<\/title>/si, text) do
      [_whole, title] ->
        title |> tagless() |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

      _none ->
        nil
    end
  end

  defp without(text, pattern), do: Regex.replace(pattern, text, " ")

  defp tagless(text) do
    text
    |> then(&Regex.replace(~r/<[^>]+>/, &1, " "))
    |> String.replace(~r/&(nbsp|#160);/, " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/[ \t\r\f\v]+/, " ")
    |> String.replace(~r/\s*\n\s*/, "\n")
  end

  defp clip(text, limit) when byte_size(text) <= limit, do: text

  defp clip(text, limit) do
    cut = binary_part(text, 0, limit)
    cut = if String.valid?(cut), do: cut, else: String.replace_invalid(cut)
    cut <> "… [#{byte_size(text) - limit} more bytes]"
  end

  @doc """
  Classifies a provider error from structured fields.

  A dropped connection (`:closed`, `:econnreset` and their kin, however the
  transport wraps them) and a `Lemieux.Provider.Interrupted` stream are
  `:server`: the provider stopped answering, which is what a `5xx` says too.
  They used to be `:other`, which read a load balancer's reset as a refusal
  and turned a mid-answer hiccup into a lost turn.
  """
  @spec category(reason :: term()) :: category()
  def category(reason) do
    cond do
      context_limit?(reason) -> :context_limit
      rate_limit?(reason) -> :rate_limit
      match?(status when status >= 500 and status <= 599, http_status(reason)) -> :server
      timeout?(reason) -> :timeout
      dropped?(reason) -> :server
      true -> :other
    end
  end

  @doc "Returns the HTTP status retained by the provider error, when present."
  @spec http_status(reason :: term()) :: non_neg_integer() | nil
  def http_status({:context_limit, reason}), do: http_status(reason)
  def http_status(%{status: status}) when is_integer(status), do: status
  def http_status(%{cause: cause}) when not is_nil(cause), do: http_status(cause)
  def http_status(_reason), do: nil

  @doc "Returns the provider's requested delay in milliseconds, when present."
  @spec retry_after_ms(reason :: term()) :: non_neg_integer() | nil
  def retry_after_ms({:context_limit, reason}), do: retry_after_ms(reason)

  def retry_after_ms(%{retry_after: retry_after}) when not is_nil(retry_after),
    do: seconds_to_ms(retry_after)

  def retry_after_ms(%{headers: headers, cause: cause}) do
    retry_after_header(headers) || retry_after_ms(cause)
  end

  def retry_after_ms(%{headers: headers}), do: retry_after_header(headers)
  def retry_after_ms(%{cause: cause}) when not is_nil(cause), do: retry_after_ms(cause)
  def retry_after_ms(_reason), do: nil

  @doc "Whether typed provider data identifies a context-window overflow."
  @spec context_limit?(reason :: term()) :: boolean()
  def context_limit?({:context_limit, _reason}), do: true

  def context_limit?(reason) do
    code = provider_code(reason)
    is_binary(code) and MapSet.member?(@context_limit_codes, normalize_code(code))
  end

  @doc """
  Marks a failure as a context-window overflow when the provider that produced
  it is known to say so in that shape.

  Most providers give an overflow a code (`context_length_exceeded`), and
  `context_limit?/1` reads those wherever they appear. Anthropic and Gemini
  do not: both refuse an oversized prompt with a generic `400` whose only
  distinguishing mark is the provider's own sentence, so a long session on
  either ended in an error instead of compacting and carrying on. Reading that
  sentence out of *any* failure would be classifying prose — the thing this
  module refuses to do — so recognition is scoped three ways: `wire_provider`
  is the provider the request actually went to (the adapter knows it; a
  failure term does not), the status must be the one that provider uses for
  the refusal, and the sentence must be that provider's.

  A match returns `{:context_limit, reason}` with the original term whole
  inside it, which every function here understands. Anything else — including
  an overflow already recognisable by its code — returns `reason` unchanged.
  """
  @spec recognize_overflow(reason :: term(), wire_provider :: String.t() | nil) :: term()
  def recognize_overflow({:context_limit, _reason} = recognized, _wire_provider), do: recognized

  def recognize_overflow(reason, wire_provider) when is_binary(wire_provider) do
    if not context_limit?(reason) and provider_overflow?(reason, wire_provider),
      do: {:context_limit, reason},
      else: reason
  end

  def recognize_overflow(reason, _wire_provider), do: reason

  @doc """
  The context window a provider stated when it refused an overflow, or `nil`.

  The refusal is often the only authoritative statement of a model's window a
  session ever gets: a model newer than the bundled catalog has no window at
  all until one of these arrives. Read only from a failure already classified
  as a context limit, so a number in some other error is never mistaken for
  one. Covers the sentences of OpenAI and its compatible servers ("maximum
  context length is N"), Anthropic ("… > N maximum"), Gemini ("… tokens
  allowed (N)") and Mistral ("… with N maximum context length").
  """
  @spec stated_context_window(reason :: term()) :: pos_integer() | nil
  def stated_context_window(reason) do
    if context_limit?(reason), do: reason |> texts() |> Enum.find_value(&stated_limit/1)
  end

  @doc """
  Whether the failure is about the account rather than the request.

  An authentication, permission, quota or billing failure: a 401, 402 or 403,
  or a `code` or `type` naming one of those, read from typed fields and the
  response body's code — never from prose. Such a failure is never retried:
  the same key against the same account gets the same answer, and waiting
  between attempts only delays telling the person to fix it. A session's
  retry policy asks this before it asks `transient?/2`, because some gateways
  mark an exhausted quota `retryable` or answer it with a 429.
  """
  @spec account?(reason :: term()) :: boolean()
  def account?(reason) do
    http_status(reason) in [401, 402, 403] or
      Enum.any?(account_codes(reason), &MapSet.member?(@account_codes, &1))
  end

  # Every code and type a failure carries, its cause's included. A body's
  # `type` counts as well as its `code`: OpenAI names an exhausted quota in
  # both, and some imitators only in the type.
  defp account_codes({:context_limit, reason}), do: account_codes(reason)

  defp account_codes(%{} = reason) do
    own =
      [Map.get(reason, :provider_code) | codes_and_types(Map.get(reason, :response_body))]
      |> Enum.flat_map(&code_string/1)
      |> Enum.map(&normalize_code/1)

    case Map.get(reason, :cause) do
      nil -> own
      cause -> own ++ account_codes(cause)
    end
  end

  defp account_codes(_reason), do: []

  defp codes_and_types(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> codes_and_types(decoded)
      {:error, _reason} -> []
    end
  end

  defp codes_and_types(%{} = body) do
    [
      Map.get(body, "code") || Map.get(body, :code),
      Map.get(body, "type") || Map.get(body, :type)
      | codes_and_types(nested_error(body))
    ]
  end

  defp codes_and_types(_body), do: []

  @doc "Whether the failure is safe for a transport-level retry before output."
  @spec retryable?(reason :: term()) :: boolean()
  def retryable?(%{retryable: retryable}) when is_boolean(retryable), do: retryable

  def retryable?(reason) do
    case http_status(reason) do
      status when status in [408, 409, 425, 429] -> true
      status when is_integer(status) and status >= 500 and status <= 599 -> true
      _status -> false
    end
  end

  @typedoc "A classifier's verdict on one failure. `:default` defers to the built-in rule."
  @type classification :: :transient | :fatal | :default

  @typedoc "A host's rule for which failures are worth a retry before any output."
  @type classifier :: (reason :: term() -> classification())

  @doc """
  Whether a failure is one the provider may not repeat, so a request that
  produced no output is worth sending again.

  Without a classifier this is the rule the session has always applied: a
  server error, a rate limit, a stalled stream, or a typed `retryable` flag.
  A host that knows its gateway better — one that answers 503 to a policy
  refusal that will never clear, say, or 400 to a transient upstream hiccup —
  passes a classifier. Its verdict wins in either direction, and `:default`
  falls back to the rule here, so a classifier only has to know about the
  cases it disagrees with. It sees the original typed reason, never a
  projection of it. Anything other than the three verdicts is a bug in the
  classifier and raises, rather than being read as one of them.

  Timing is separate: `Lemieux.Session`'s `:provider_retry` decides how many
  attempts and how long between them, and reads `retry_after_ms/1` itself.
  """
  @spec transient?(reason :: term(), classifier :: classifier() | nil) :: boolean()
  def transient?(reason, classifier \\ nil)
  def transient?(reason, nil), do: default_transient?(reason)

  def transient?(reason, classifier) when is_function(classifier, 1) do
    case classifier.(reason) do
      :transient ->
        true

      :fatal ->
        false

      :default ->
        default_transient?(reason)

      other ->
        raise ArgumentError,
              "a provider retry classifier must return :transient, :fatal or :default, got: " <>
                inspect(other)
    end
  end

  defp default_transient?(reason),
    do: category(reason) in [:server, :rate_limit, :timeout] or retryable?(reason)

  defp rate_limit?(reason) do
    code = provider_code(reason)

    http_status(reason) == 429 or
      (is_binary(code) and MapSet.member?(@rate_limit_codes, normalize_code(code)))
  end

  # A stream that stalls mid-answer is not a `ReqLLM.Error.API.Timeout`:
  # `ReqLLM.StreamServer` replies `{:error, :timeout}`, req_llm's lazy stream raises
  # `ReqLLM.Error.API.Stream` carrying that atom as `:cause`, and Finch/Mint
  # transport errors carry it as `:reason`. Matching only the typed exception left
  # every stalled stream in `:other`, where the evaluation lane could not tell a
  # dead connection from a refused request.
  defp timeout?(:timeout), do: true
  defp timeout?(%ReqLLM.Error.API.Timeout{}), do: true
  defp timeout?(%{reason: :timeout}), do: true
  defp timeout?(%{cause: cause}) when not is_nil(cause), do: timeout?(cause)
  defp timeout?(_reason), do: false

  defp dropped?(%Interrupted{}), do: true
  defp dropped?(reason) when reason in @dropped_transport_reasons, do: true
  defp dropped?(%{reason: reason}) when reason in @dropped_transport_reasons, do: true
  defp dropped?(%{cause: cause}) when not is_nil(cause), do: dropped?(cause)
  defp dropped?(_reason), do: false

  # Gated by status first: a sentence only counts in the refusal the provider
  # actually sends it with.
  defp provider_overflow?(reason, provider) do
    http_status(reason) in [400, 413] and
      (overflow_code?(provider, reason) or
         Enum.any?(texts(reason), &overflow_sentence?(provider, &1)))
  end

  defp overflow_code?(provider, reason) when provider in @zai_providers,
    do: "1261" in codes(reason)

  defp overflow_code?(_provider, _reason), do: false

  defp overflow_sentence?(provider, text) do
    provider |> overflow_patterns() |> Enum.any?(&Regex.match?(&1, text))
  end

  # Kept in functions rather than module attributes: a compiled regex is not a
  # portable literal across OTP releases.
  defp overflow_patterns("anthropic"), do: [~r/\bprompt is too long\b/i]

  defp overflow_patterns("amazon_bedrock"),
    do: [
      ~r/\bprompt is too long\b/i,
      ~r/\binput is too long for requested model\b/i,
      ~r/\btoo many input tokens\b/i
    ]

  defp overflow_patterns("google"), do: [~r/\bexceeds the maximum number of tokens allowed\b/i]

  defp overflow_patterns("google_vertex"),
    do: overflow_patterns("anthropic") ++ overflow_patterns("google")

  defp overflow_patterns(provider) when provider in @openai_wire_providers,
    do: [
      ~r/\bmaximum context length is \d+/i,
      ~r/\bmaximum prompt length is \d+/i,
      ~r/\btoo large for model with \d+ maximum context length\b/i,
      ~r/\bexceeds (?:the )?(?:available context size|maximum context length)\b/i
    ]

  defp overflow_patterns(_provider), do: []

  defp stated_limit(text) do
    Enum.find_value(stated_limit_patterns(), fn pattern ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        [digits] -> positive_integer(digits)
        _none -> nil
      end
    end)
  end

  # Most specific first: Mistral's sentence also contains "N maximum".
  defp stated_limit_patterns,
    do: [
      ~r/\bmaximum context length is (\d+)/i,
      ~r/\bmaximum prompt length is (\d+)/i,
      ~r/\bwith (\d+) maximum context length\b/i,
      ~r/\btokens allowed \((\d+)\)/i,
      ~r/\b(\d+) maximum\b/i
    ]

  defp positive_integer(digits) do
    case Integer.parse(digits) do
      {value, ""} when value > 0 -> value
      _invalid -> nil
    end
  end

  # Every human-readable string a failure carries: its reason, its message and
  # its response body's message, then its cause's. Only ever read after the
  # failure has been gated by provider and status, or classified by code.
  defp texts({:context_limit, reason}), do: texts(reason)

  defp texts(%{} = reason) do
    own =
      Enum.filter(
        [
          Map.get(reason, :reason),
          Map.get(reason, :message),
          body_message(Map.get(reason, :response_body))
        ],
        &is_binary/1
      )

    case Map.get(reason, :cause) do
      nil -> own
      cause -> own ++ texts(cause)
    end
  end

  defp texts(reason) when is_binary(reason), do: [reason]
  defp texts(_reason), do: []

  defp body_message(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> body_message(decoded)
      {:error, _reason} -> body
    end
  end

  defp body_message(%{} = body) do
    case Map.get(body, "message") || Map.get(body, :message) do
      message when is_binary(message) -> message
      _missing -> body |> nested_error() |> body_message()
    end
  end

  defp body_message(_body), do: nil

  defp nested_error(body), do: Map.get(body, "error") || Map.get(body, :error)

  # Codes as strings, integers included: Z.AI's is numeric, where the codes
  # `provider_code/1` reads are names.
  defp codes({:context_limit, reason}), do: codes(reason)

  defp codes(%{} = reason) do
    own =
      [Map.get(reason, :provider_code) | body_codes(Map.get(reason, :response_body))]
      |> Enum.flat_map(&code_string/1)

    case Map.get(reason, :cause) do
      nil -> own
      cause -> own ++ codes(cause)
    end
  end

  defp codes(_reason), do: []

  defp body_codes(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> body_codes(decoded)
      {:error, _reason} -> []
    end
  end

  defp body_codes(%{} = body) do
    [Map.get(body, "code") || Map.get(body, :code) | body_codes(nested_error(body))]
  end

  defp body_codes(_body), do: []

  defp code_string(code) when is_binary(code), do: [String.trim(code)]
  defp code_string(code) when is_integer(code), do: [Integer.to_string(code)]

  defp code_string(code) when is_atom(code) and not is_nil(code) and not is_boolean(code),
    do: [Atom.to_string(code)]

  defp code_string(_code), do: []

  defp provider_code(%{provider_code: code}) when is_atom(code), do: Atom.to_string(code)
  defp provider_code(%{provider_code: code}) when is_binary(code), do: code

  defp provider_code(%{response_body: body, cause: cause}) do
    body_code(body) || provider_code(cause)
  end

  defp provider_code(%{response_body: body}), do: body_code(body)
  defp provider_code(%{cause: cause}) when not is_nil(cause), do: provider_code(cause)
  defp provider_code(_reason), do: nil

  defp body_code(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> body_code(decoded)
      {:error, _reason} -> nil
    end
  end

  defp body_code(body) when is_map(body) do
    direct =
      Map.get(body, "code") || Map.get(body, :code) || Map.get(body, "type") ||
        Map.get(body, :type)

    cond do
      is_binary(direct) -> direct
      is_atom(direct) -> Atom.to_string(direct)
      is_map(Map.get(body, "error")) -> body_code(Map.get(body, "error"))
      is_map(Map.get(body, :error)) -> body_code(Map.get(body, :error))
      true -> nil
    end
  end

  defp body_code(_body), do: nil

  defp retry_after_header(headers) when is_map(headers) do
    headers
    |> Enum.find_value(fn {name, value} -> retry_after_value(name, value) end)
  end

  defp retry_after_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} -> retry_after_value(name, value)
      _other -> nil
    end)
  end

  defp retry_after_header(_headers), do: nil

  defp retry_after_value(name, value) do
    if name |> to_string() |> String.downcase() == "retry-after" do
      value |> List.wrap() |> List.first() |> seconds_to_ms()
    end
  end

  defp seconds_to_ms(value) when is_integer(value) and value >= 0, do: value * 1_000
  defp seconds_to_ms(value) when is_float(value) and value >= 0, do: ceil(value * 1_000)

  defp seconds_to_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> ceil(seconds * 1_000)
      _invalid -> nil
    end
  end

  defp seconds_to_ms(_value), do: nil

  defp normalize_code(code), do: code |> String.trim() |> String.downcase()
end
