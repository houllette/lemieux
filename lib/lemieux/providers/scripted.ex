defmodule Lemieux.Providers.Scripted do
  @moduledoc """
  A `Lemieux.Provider` that replays a script and records what it was asked.

  This ships in the library rather than living in `test/support` on purpose.
  An embedder has the same problem lemieux has — proving that its hooks, its
  store and its UI do the right thing on a tool call, a mid-stream failure,
  a cancelled turn — and every one of those tests wants a model that answers
  the same way twice, instantly, with no key and no network.

  ## Scripting

  The script is a list of turns, one per request. A turn is either a list of
  `Lemieux.Provider` events and `{:delay, milliseconds}` directives, or a
  function from the `Lemieux.Request` to that list, for when a later turn's
  answer depends on what the loop actually sent.

      provider =
        Scripted.new([
          [{:tool_call, %{id: "1", name: "read", arguments: %{}}}, {:done, :tool_calls}],
          [{:text_delta, "the file says hello"}, {:done, :stop}]
        ])

  `requests/1` returns every request the provider received, in order, so a
  test can assert on the exact conversation the loop built — which is the
  half of the loop's behaviour that is invisible from its output.

  Pass `estimated_cost_usd: number_or_fun` to exercise a session cost gate.
  With no estimate, a session that has `:max_cost_usd` correctly treats this
  provider as unpriced and refuses to spend.

  Prefer the builders in this module for host contract tests. They describe
  observable Provider behavior rather than `req_llm` chunks or vendor SSE, so
  they stay useful when the real adapter changes internally.

  Running past the end of the script emits `{:error, {:scripted,
  :script_exhausted, n}}` rather than raising. A test double that raises
  inside the caller's task reports itself as a crashed session, which sends
  whoever is reading the failure looking in the wrong module; an error event
  travels the ordinary failure path and arrives named.

  ## The process

  `new/1` starts an `Agent` linked to the calling process, so a provider
  created in a test dies with that test and there is nothing to clean up.
  """

  @behaviour Lemieux.Provider

  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Provider.Interrupted
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Request

  @typedoc "A test-only pause in the provider task."
  @type directive :: {:delay, non_neg_integer()}

  @typedoc "One request's worth of events, or a function that computes them."
  @type turn ::
          [Lemieux.Provider.event() | directive()]
          | (Request.t() -> [Lemieux.Provider.event() | directive()])

  @doc """
  Builds a provider that will replay `script`, one turn per request.
  """
  @spec new(script :: [turn()], opts :: keyword()) :: Lemieux.Provider.t()
  def new(script, opts \\ []) when is_list(script) and is_list(opts) do
    estimate = Keyword.get(opts, :estimated_cost_usd)

    {:ok, agent} =
      Agent.start_link(fn -> %{script: script, requests: [], estimated_cost_usd: estimate} end)

    {__MODULE__, agent}
  end

  @doc """
  Returns every request this provider has been given, oldest first.
  """
  @spec requests(provider :: Lemieux.Provider.t()) :: [Request.t()]
  def requests({__MODULE__, agent}) do
    Agent.get(agent, fn state -> Enum.reverse(state.requests) end)
  end

  @doc "Builds a successful text response, optionally split into `:fragments`."
  @spec complete(text :: String.t(), opts :: keyword()) :: turn()
  def complete(text, opts \\ []) when is_binary(text) and is_list(opts) do
    fragments = Keyword.get(opts, :fragments, [text])
    usage = Keyword.get(opts, :usage)
    finish_reason = Keyword.get(opts, :finish_reason, :stop)

    Enum.map(fragments, &{:text_delta, &1}) ++
      optional({:usage, usage}, usage) ++ [{:done, finish_reason}]
  end

  @doc "Builds a response with thinking followed by text."
  @spec thinking(thinking :: String.t(), text :: String.t(), opts :: keyword()) :: turn()
  def thinking(thinking, text, opts \\ [])
      when is_binary(thinking) and is_binary(text) and is_list(opts) do
    thinking_fragments = Keyword.get(opts, :thinking_fragments, [thinking])
    text_fragments = Keyword.get(opts, :fragments, [text])

    Enum.map(thinking_fragments, &{:thinking_delta, &1}) ++
      Enum.map(text_fragments, &{:text_delta, &1}) ++
      optional({:usage, Keyword.get(opts, :usage)}, Keyword.get(opts, :usage)) ++
      [{:done, Keyword.get(opts, :finish_reason, :stop)}]
  end

  @doc "Builds one normalized tool call and its terminal event."
  @spec tool_call(id :: String.t(), name :: String.t(), arguments :: map(), opts :: keyword()) ::
          turn()
  def tool_call(id, name, arguments, opts \\ [])
      when is_binary(id) and is_binary(name) and is_map(arguments) and is_list(opts) do
    tool_calls([%{id: id, name: name, arguments: arguments}], opts)
  end

  @doc "Builds several normalized tool calls in provider order."
  @spec tool_calls(calls :: [Lemieux.Provider.tool_call()], opts :: keyword()) :: turn()
  def tool_calls(calls, opts \\ []) when is_list(calls) and is_list(opts) do
    Enum.map(calls, &{:tool_call, &1}) ++
      optional({:usage, Keyword.get(opts, :usage)}, Keyword.get(opts, :usage)) ++
      [{:done, Keyword.get(opts, :finish_reason, :tool_calls)}]
  end

  @doc "Builds a malformed tool call as the real provider boundary reports it."
  @spec invalid_tool_call(id :: String.t(), name :: String.t(), raw_arguments :: term()) :: turn()
  def invalid_tool_call(id, name, raw_arguments) when is_binary(id) and is_binary(name) do
    {:error, reason} = ReqLLMProvider.decode_arguments(raw_arguments)

    tool_calls([
      %{id: id, name: name, arguments: %{}, argument_error: reason}
    ])
  end

  @doc "Builds a terminal typed provider failure."
  @spec error(reason :: term()) :: turn()
  def error(reason), do: [{:error, reason}]

  @doc "Builds a typed ReqLLM HTTP failure for rate-limit and server-path tests."
  @spec http_error(status :: pos_integer(), opts :: keyword()) :: turn()
  def http_error(status, opts \\ []) when is_integer(status) and status > 0 and is_list(opts) do
    reason =
      ReqLLM.Error.API.Request.exception(
        reason: Keyword.get(opts, :reason, "HTTP #{status}"),
        status: status,
        headers: Keyword.get(opts, :headers),
        provider_code: Keyword.get(opts, :provider_code),
        retryable: Keyword.get(opts, :retryable)
      )

    error(reason)
  end

  @doc """
  Builds the mid-stream stall a provider produces when its connection goes
  quiet.

  Shipped rather than hand-rolled in each test because the shape is not
  obvious: `ReqLLM.StreamServer` answers its consumer `{:error, :timeout}`,
  and req_llm's lazy stream turns that into a `ReqLLM.Error.API.Stream`
  carrying the atom as `:cause` — not the typed `API.Timeout` a reader would
  expect. `Lemieux.Provider.Error.category/1` classifies it as `:timeout`,
  which is what tells a dead connection from a wrong answer.
  """
  @spec stream_timeout(opts :: keyword()) :: turn()
  def stream_timeout(opts \\ []) when is_list(opts) do
    error(
      ReqLLM.Error.API.Stream.exception(
        reason: Keyword.get(opts, :reason, "Stream failed: :timeout"),
        cause: Keyword.get(opts, :cause, :timeout)
      )
    )
  end

  @doc "Builds the typed overflow used to exercise safe context recovery."
  @spec context_limit(reason :: String.t()) :: turn()
  def context_limit(reason \\ "the provider rejected an oversized context") do
    http_error(400, reason: reason, provider_code: "context_length_exceeded")
  end

  @doc """
  Builds an overflow the way the real adapter reports Anthropic's: a generic
  `400` recognised by its sentence, stating the model's window.

  `Lemieux.Provider.Error.stated_context_window/1` reads `window` back out of
  it, which is how a session can learn the real size of a model the catalog
  does not know. Pass `:tokens` for the size of the refused prompt.
  """
  @spec stated_context_limit(window :: pos_integer(), opts :: keyword()) :: turn()
  def stated_context_limit(window, opts \\ [])
      when is_integer(window) and window > 0 and is_list(opts) do
    message =
      "prompt is too long: #{Keyword.get(opts, :tokens, window + 1)} tokens > #{window} maximum"

    reason =
      ReqLLM.Error.API.Request.exception(
        reason: message,
        status: 400,
        provider_code: "invalid_request_error",
        response_body: %{"type" => "invalid_request_error", "message" => message}
      )

    error(ProviderError.recognize_overflow(reason, "anthropic"))
  end

  @doc """
  Builds a stream that broke off after some of the answer arrived.

  The sequence the real adapter emits for Anthropic's dropped `error` event or
  an OpenAI-compatible error inside a `200`: the text as it streamed, the
  assembled fragment marked `"partial" => true`, any usage, then a
  `Lemieux.Provider.Interrupted` — a retryable `:server` failure. Pass
  `:fragments`, `:usage` and `:detail` (the provider's sentence).
  """
  @spec interrupted(text :: String.t(), opts :: keyword()) :: turn()
  def interrupted(text, opts \\ []) when is_binary(text) and is_list(opts) do
    fragments = Keyword.get(opts, :fragments, [text])
    usage = Keyword.get(opts, :usage)
    content = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    Enum.map(fragments, &{:text_delta, &1}) ++
      [{:message, %{"content" => content, "partial" => true}}] ++
      optional({:usage, usage}, usage) ++
      [
        {:error,
         %Interrupted{
           provider: Keyword.get(opts, :provider, "anthropic"),
           detail: Keyword.get(opts, :detail)
         }}
      ]
  end

  @doc "Delays a scripted turn inside its already-supervised provider task."
  @spec delayed(delay_ms :: non_neg_integer(), turn :: turn()) :: turn()
  def delayed(delay_ms, turn) when is_integer(delay_ms) and delay_ms >= 0 and is_list(turn),
    do: [{:delay, delay_ms} | turn]

  @impl Lemieux.Provider
  def run(agent, %Request{} = request, emit) do
    agent
    |> Agent.get_and_update(fn state ->
      {{next(state.script), length(state.requests) + 1},
       %{state | script: Enum.drop(state.script, 1), requests: [request | state.requests]}}
    end)
    |> events(request)
    |> Enum.each(fn
      {:delay, delay_ms} -> Process.sleep(delay_ms)
      event -> emit.(event)
    end)
  end

  @impl Lemieux.Provider
  def estimate_cost(agent, %Request{} = request) do
    Agent.get(agent, fn
      %{estimated_cost_usd: estimate} when is_function(estimate, 1) -> estimate.(request)
      %{estimated_cost_usd: estimate} -> estimate
    end)
  end

  defp next([]), do: :exhausted
  defp next([turn | _rest]), do: turn

  defp events({:exhausted, position}, _request),
    do: [{:error, {:scripted, :script_exhausted, position}}]

  defp events({turn, _position}, request) when is_function(turn, 1), do: turn.(request)
  defp events({turn, _position}, _request) when is_list(turn), do: turn

  defp optional(_event, nil), do: []
  defp optional(event, _value), do: [event]
end
