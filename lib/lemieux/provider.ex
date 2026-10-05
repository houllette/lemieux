defmodule Lemieux.Provider do
  @moduledoc """
  The seam between the agent loop and the model.

  **This is a test seam, not a provider adapter.** lemieux has exactly one
  real implementation of it, `Lemieux.Providers.ReqLLM`, and adding a second
  one that speaks HTTP to some vendor is not how this library grows — a new
  provider is `req_llm`'s problem, and reopening that decision here would put
  lemieux back in the business of tracking other people's API changes. What
  this behaviour buys is different: every rule in the loop can be tested
  against a scripted stream (`Lemieux.Providers.Scripted`), in milliseconds,
  offline, with the request recorded so a test can assert on exactly what the
  model would have been sent.

  Like `Lemieux.Store`, a provider is a `{module, state}` pair, so one VM can
  hold several with different configuration.

  ## Why events are pushed rather than streamed

  `run/3` blocks and calls `emit` for each event, instead of returning a lazy
  stream of them. A stream would be the more Elixir-shaped answer and it buys
  laziness this caller never uses: the loop consumes every event to the end,
  and the one way it stops early is cancellation — which is killing the
  process doing the consuming, not halting an enumerable. Meanwhile the push
  shape costs nothing to implement on either side. `req_llm`'s streaming API
  is itself callback-driven, so a lazy version would need a process to bridge
  it; the scripted double is `Enum.each/2`.

  The caller runs `run/3` in a task of its own and forwards events to itself,
  so a slow provider never blocks the session, and cancelling is killing that
  task.

  ## Events

    * `{:text_delta, binary}` and `{:thinking_delta, binary}` — provider chunks
      as they arrive. The session adds the destination entry id before these
      become subscriber events.
    * `{:tool_call, %{id:, name:, arguments:}}` — one assembled call.
    * `{:message, payload}` — the assistant message as the provider assembled
      it, JSON-shaped, ready to be persisted and sent back. Optional, and
      authoritative when present: see `Lemieux.Turn`. It may also precede an
      `{:error, _}`, carrying `"partial" => true`, when a stream broke off
      after some of the answer arrived: the assembled fragment keeps what the
      deltas cannot — Anthropic's signatures on the thinking blocks that did
      complete — and a request never replays it as the last word of a
      conversation (see `Lemieux.Providers.ReqLLM.context/2`).
    * `{:usage, payload}` — token accounting, JSON-shaped.
    * `{:response_metadata, metadata}` — optional ephemeral HTTP status,
      selected response headers, requested/resolved model and request correlation.
      It precedes the terminal event or error return and is not transcript data.
    * `{:context_window, tokens}` — optional: the window the endpoint that
      served this request says it gave the model. A server that sizes the
      window when it loads a model, and drops what does not fit rather than
      refusing it, is the case it exists for: `Lemieux.Providers.ReqLLM`
      reports what a local Ollama daemon served. Not output and not
      progress; a session plans compaction against it unless its host
      configured a window, and never against more than it. It precedes the
      terminal event.
    * `{:done, stop_reason}` — the last event of a successful request.
    * `{:error, reason}` — the last event of a failed one. Keep the provider's
      typed reason intact; policy reads it through `Lemieux.Provider.Error`
      and human-facing code formats it only at its presentation boundary.

  Exactly one of `{:done, _}` or `{:error, _}` must be emitted, last. A
  provider that returns `{:error, reason}` from `run/3` without emitting
  anything is also fine — that is the shape of a request that never left the
  machine, such as a missing API key — and the caller treats it the same way.
  """

  alias Lemieux.Request

  @typedoc "An implementation module paired with its own state."
  @type t :: {module(), state :: term()}

  @typedoc "One assembled tool call, including a typed decode failure when arguments were malformed."
  @type tool_call :: %{
          optional(:argument_error) => term(),
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @typedoc """
  Progress on a tool call the model is still composing.

  `name` arrives when the provider announces the call, `fragment` with each
  piece of its arguments, and either may be absent. Informational only: the
  call itself still arrives whole as `{:tool_call, call}`. It exists because
  a model writing a 35 KB file is silent for minutes on every other channel,
  and a front end with nothing to draw looks hung.
  """
  @type tool_call_delta :: %{
          optional(:index) => non_neg_integer(),
          optional(:name) => String.t(),
          optional(:fragment) => String.t()
        }

  @typedoc """
  Ephemeral response facts for one provider attempt. `request_id` is the
  Lemieux request id, not a gateway id; selected gateway ids live in headers.
  Header names are lowercase and values remain lists. A missing status or
  disclosed model is nil, never inferred from the requested model. Transport
  failure can precede metadata availability. Custom providers may omit this
  event. Sessions forward it without persisting it or treating it as output.
  """
  @type response_metadata :: %{
          request_id: String.t() | nil,
          requested_model: String.t(),
          resolved_model: String.t() | nil,
          status: non_neg_integer() | nil,
          headers: %{String.t() => [String.t()]}
        }

  @type event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call_delta, tool_call_delta()}
          | {:tool_call, tool_call()}
          | {:message, map()}
          | {:usage, map()}
          | {:response_metadata, response_metadata()}
          | {:context_window, pos_integer()}
          | {:done, atom()}
          | {:error, term()}

  @typedoc "Called once per event, in order, from the process running `run/3`."
  @type emit :: (event() -> any())

  @doc """
  Runs one request to completion, calling `emit` for each event.
  """
  @callback run(state :: term(), request :: Request.t(), emit :: emit()) :: :ok | {:error, term()}

  @doc """
  How many tokens this model's context window holds, or `nil` if unknown.

  Optional, and here rather than on `Lemieux.Context` because the provider is
  the only thing that knows what a model specification means. `req_llm` ships a
  model database with the answer; a scripted double in a test does not, and
  should say so rather than guess. A model whose window is a server setting —
  one a local daemon serves — is answered by asking the server, when the
  provider can.

  `nil` is a real answer, not a failure. The session then plans compaction
  against `planning_window/2`'s fallback and says it is doing so, rather than
  presenting a guess as knowledge; `Lemieux.Context` still reports the window
  as unknown.
  """
  @callback context_window(state :: term(), model :: String.t()) :: pos_integer() | nil

  @doc """
  Lists models this provider can use in the current environment.

  Optional because discovery is a convenience for interactive hosts, not a
  requirement for running a request. A provider without a catalog returns an
  empty list and still accepts model specifications supplied directly.
  """
  @callback available_models(state :: term(), opts :: keyword()) :: [String.t()]

  @doc "Optional display metadata keyed by model specification. Empty when unavailable."
  @callback model_metadata(state :: term()) :: %{optional(String.t()) => map()}

  @doc """
  Checks whether a model can run with the tools a session currently offers.

  Optional providers accept the change and let their ordinary request path
  report any provider-specific problem. The real req_llm implementation can
  answer before a turn starts, which keeps a bad selection from becoming
  persisted session configuration.
  """
  @callback validate_model(state :: term(), model :: String.t(), tools :: [term()]) ::
              :ok | {:error, term()}

  @doc """
  Lists the reasoning-effort values a model accepts.

  Optional because capability discovery is a convenience for interactive
  hosts. An empty list means the provider cannot confidently offer an effort
  selector for this model; it does not mean the model cannot reason.

  Values are strings because they cross command input and transcript JSON.
  Implementations may include `"default"`, which means removing an explicit
  effort and returning control to the provider.
  """
  @callback reasoning_efforts(state :: term(), model :: String.t()) :: [String.t()]

  @doc """
  A realistic upper USD cost estimate for a request, or `nil` when it cannot be
  priced.

  Optional because scripted and host-supplied providers may not have a model
  catalog. A session with `:max_cost_usd` treats `nil` as unknown and refuses
  the request; unknown pricing must not silently become free. Realistic rather
  than worst-case: a gate that reserves a model's whole output limit and prices
  every byte as a token stops a `$5` session after two or three turns while the
  real spend is cents.
  """
  @callback estimate_cost(state :: term(), request :: Request.t()) :: number() | nil

  @doc """
  What `model` can be shown besides text, e.g. `[:text, :image, :pdf]`, or
  `:unknown`.

  Optional: a provider without a model catalog answers nothing, and
  `input_modalities/2` treats that as `:unknown`, so tools attach nothing
  a model is not known to read.
  """
  @callback input_modalities(state :: term(), model :: String.t()) :: [atom()] | :unknown

  @optional_callbacks model_metadata: 1,
                      context_window: 2,
                      available_models: 2,
                      validate_model: 3,
                      reasoning_efforts: 2,
                      estimate_cost: 2,
                      input_modalities: 2

  @doc """
  Runs one request to completion, calling `emit` for each event.
  """
  @spec run(provider :: t(), request :: Request.t(), emit :: emit()) :: :ok | {:error, term()}
  def run({module, state}, %Request{} = request, emit) when is_function(emit, 1) do
    module.run(state, request, emit)
  end

  @doc """
  How many tokens this model's context window holds, or `nil`.

  `nil` for a provider that does not implement the callback, so a host can add
  one without every existing double having to grow a function it has no answer
  for.
  """
  @spec context_window(provider :: t(), model :: String.t()) :: pos_integer() | nil
  def context_window({module, state}, model) when is_binary(model) do
    if function_exported?(module, :context_window, 2) do
      module.context_window(state, model)
    end
  end

  def context_window(_provider, _model), do: nil

  # Large enough that no current API model is compacted absurdly early, small
  # enough that a newer model the catalog has not heard of is compacted well
  # before most real windows overflow. A local model is the case a guess
  # cannot correct: Ollama truncates silently rather than refusing, so no
  # overflow ever arrives. Its provider asks the daemon instead, before the
  # first request when the model is loaded and after every answer
  # (`{:context_window, tokens}`), and the session replaces this number with
  # what it hears.
  @fallback_context_window 128_000

  @doc """
  The window to plan compaction against, and where it came from.

  `context_window/2`'s `nil` stays the honest answer to "how big is this
  window?". This is the answer to a different question — "what should a
  session assume?" — for a host that would rather compact early than let a
  session run into a provider refusal on a model the catalog has not caught
  up with. `:fallback` says the number is `fallback_context_window/0` rather
  than knowledge, so a host can tell the person using it. A refusal that
  states the real window (`Lemieux.Provider.Error.stated_context_window/1`)
  is the way to replace the guess.
  """
  @spec planning_window(provider :: t(), model :: String.t()) ::
          {pos_integer(), :provider | :fallback}
  def planning_window(provider, model) when is_binary(model) do
    case context_window(provider, model) do
      window when is_integer(window) and window > 0 -> {window, :provider}
      _unknown -> {@fallback_context_window, :fallback}
    end
  end

  @doc "The window `planning_window/2` assumes when the provider does not know one."
  @spec fallback_context_window() :: pos_integer()
  def fallback_context_window, do: @fallback_context_window

  @doc """
  Lists models the provider reports as currently available.

  Providers without discovery return an empty list rather than preventing a
  host from accepting a model specification directly.
  """
  @spec available_models(provider :: t(), opts :: keyword()) :: [String.t()]
  def available_models({module, state}, opts \\ []) when is_list(opts) do
    if function_exported?(module, :available_models, 2) do
      module.available_models(state, opts)
    else
      []
    end
  end

  @doc "Returns provider-supplied picker metadata without changing model availability."
  @spec model_metadata(provider :: t()) :: %{optional(String.t()) => map()}
  def model_metadata({module, state}) do
    if function_exported?(module, :model_metadata, 1), do: module.model_metadata(state), else: %{}
  end

  @doc """
  Validates a model against a provider and the session's current tools.

  Providers without this optional callback accept the model. Their normal
  request validation remains the final authority.
  """
  @spec validate_model(provider :: t(), model :: String.t(), tools :: [term()]) ::
          :ok | {:error, term()}
  def validate_model({module, state}, model, tools)
      when is_binary(model) and is_list(tools) do
    if function_exported?(module, :validate_model, 3) do
      module.validate_model(state, model, tools)
    else
      :ok
    end
  end

  @doc "Returns the reasoning-effort choices a provider reports for a model."
  @spec reasoning_efforts(provider :: t(), model :: String.t()) :: [String.t()]
  def reasoning_efforts({module, state}, model) when is_binary(model) do
    if function_exported?(module, :reasoning_efforts, 2) do
      module.reasoning_efforts(state, model)
    else
      []
    end
  end

  @doc """
  What `model` can be shown besides text — for example `[:text, :image, :pdf]` —
  or `:unknown`.

  `:unknown` for a provider that does not implement the callback, and it is
  its own answer rather than a guess either way: an image sent to a model that
  cannot read it is refused on every later request that still carries it, so
  a tool only attaches what a model is known to accept.
  """
  @spec input_modalities(provider :: t(), model :: String.t()) :: [atom()] | :unknown
  def input_modalities({module, state}, model) when is_binary(model) do
    if function_exported?(module, :input_modalities, 2),
      do: module.input_modalities(state, model),
      else: :unknown
  end

  def input_modalities(_provider, _model), do: :unknown

  @doc "Returns a provider's realistic upper request-cost estimate, or `nil`."
  @spec estimate_cost(provider :: t(), request :: Request.t()) :: number() | nil
  def estimate_cost({module, state}, %Request{} = request) do
    if function_exported?(module, :estimate_cost, 2) do
      module.estimate_cost(state, request)
    end
  end
end
