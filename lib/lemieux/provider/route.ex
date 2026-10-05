defmodule Lemieux.Provider.Route do
  @moduledoc """
  A destination that owns which models exist and where a request goes, for an
  adapter that owns only how a request is encoded and streamed.

  `Lemieux.Providers.ReqLLM` normally answers every question about a model
  from `req_llm`'s catalog and sends the request wherever `req_llm` sends that
  provider's traffic. A gateway changes every one of those answers at once:
  its catalog is the authority on which models the key may use, its ceilings
  are the context window, its policy decides which upstream serves the
  request, and its response headers say what actually served it. Before this
  behaviour the adapter branched on `%State{ixway: ...}` in six callbacks and
  called `Lemieux.Ixway` by name, while `Lemieux.Ixway` matched the adapter's
  state struct back — a two-file compile cycle `mix xref graph --format
  cycles` reported, and a second gateway would have meant a seventh branch in
  each callback. Now the adapter holds a `{module, state}` pair and asks it.
  The shipped implementation is `Lemieux.Ixway`; the adapter no longer knows
  its name.

  ## What a route owns and what it does not

  A route owns discovery, selection and validation, the wire target (the
  model `req_llm` will encode for and the request options that go with it,
  credentials and base URL included), the context window, the reasoning
  effort menu and, optionally, a pessimistic cost estimate and whatever the
  response disclosed about routing. It does not own encoding, tool calling,
  structured output, SSE framing or error typing — those stay `req_llm`'s —
  and it does not own admission or retries, which are
  `Lemieux.Provider.Admission`'s and the session's.

  A route excludes the adapter's direct-provider options. `:api_key`,
  `:api_keys`, `:api_key_defaults`, `:api_key_provider`, `:base_url` and
  `:transport_routes` are refused alongside `:route`, because a gateway that
  could fall back to a direct credential on a bad day would be sending a
  tenant's traffic somewhere its policy never approved.

  ## Errors

  A route returns its own typed reasons, and they travel unchanged through
  `Lemieux.Provider.run/3` and `Lemieux.Provider.validate_model/3`. A reason
  a person will read should describe itself — an exception struct whose
  `message/1` produces the sentence, as `Lemieux.Ixway.Error` does — because
  `Lemieux.Provider.Error.message/1` renders exceptions and deliberately
  knows no gateway's vocabulary.

  ## The streaming hooks

  Three optional callbacks bracket one streamed response. `c:observe_stream/3`
  sees the `ReqLLM.StreamResponse` before it is consumed and may extend its
  stream; the shipped route appends a tail that reads response headers after
  the last chunk, which is the only moment `req_llm` exposes them.
  `c:finish_stream/3` sees the consumed result and may attach what it
  learned. `c:annotate_message/3` sees the JSON-shaped assistant message
  about to be emitted and may add route-owned keys to it. `c:after_stream/3`
  runs after the terminal provider event and may start a noncritical task;
  it must return without waiting for that task. The reference is
  one per request and the same in both stream hooks, so a route that must
  carry data from the tail of the stream to the finish can key a
  self-message on it. All four are identity when absent, and when there is
  no route at all — the wrappers here accept `nil` so the adapter's direct
  path reads the same as its routed one.
  """

  alias Lemieux.Request

  @typedoc "An implementation module paired with its own state."
  @type t :: {module(), state :: term()}

  @typedoc """
  What one request is sent as: anything `ReqLLM.stream_text/3` accepts as a
  model, with the request options that go with it.
  """
  @type target :: {model :: term(), options :: keyword()}

  @typedoc "A consumed stream, as `ReqLLM.StreamResponse.process_stream/2` returns it."
  @type result :: {:ok, ReqLLM.Response.t()} | {:error, term()}

  @doc """
  Lists the model specifications this route can serve.

  `opts` are the filters `Lemieux.Provider.available_models/2` documents —
  `:provider`, `:scope`, `:require` — and a route that is not the provider
  asked about answers `[]` rather than its whole catalog.
  """
  @callback available_models(state :: term(), opts :: keyword()) :: [String.t()]

  @doc "Optional picker metadata keyed by model specification; never controls admission."
  @callback model_metadata(state :: term()) :: %{optional(String.t()) => map()}

  @doc "Checks that `model` may run with `tools`, before a session adopts it."
  @callback validate_model(state :: term(), model :: String.t(), tools :: [term()]) ::
              :ok | {:error, term()}

  @doc "How many tokens `model`'s window holds here, or `nil` when the route does not say."
  @callback context_window(state :: term(), model :: String.t()) :: pos_integer() | nil

  @doc """
  The reasoning-effort values `model` accepts, least effort first.

  Without the adapter's `"default"` sentinel: that means sending no effort
  at all and is the adapter's idea, not the route's, so the adapter adds it.
  """
  @callback reasoning_efforts(state :: term(), model :: String.t()) :: [String.t()]

  @doc """
  Resolves the wire target for one request.

  `options` are the adapter's provider options merged with the request's own
  parameters. The route decides which of them may cross to the wire: a
  session parameter must never be able to replace the destination, its
  credential or its headers, and the shipped route takes an allowlist.
  """
  @callback target(state :: term(), request :: Request.t(), options :: keyword()) ::
              {:ok, target()} | {:error, term()}

  @doc "A pessimistic USD estimate, or `nil` when the route cannot price the request. Absent means `nil`."
  @callback estimate_cost(state :: term(), request :: Request.t()) :: number() | nil

  @doc "Sees the response before its stream is consumed; may extend the stream."
  @callback observe_stream(
              state :: term(),
              response :: ReqLLM.StreamResponse.t(),
              reference :: reference()
            ) :: ReqLLM.StreamResponse.t()

  @doc "Sees the consumed result; may attach what the stream disclosed."
  @callback finish_stream(state :: term(), result :: result(), reference :: reference()) ::
              result()

  @doc "Starts optional work after the successful response has been emitted; it must not delay the answer."
  @callback after_stream(state :: term(), request :: Request.t(), reference :: reference()) ::
              :ok

  @doc "Sees the assistant message about to be emitted; may add route-owned keys."
  @callback annotate_message(state :: term(), message :: map(), response :: ReqLLM.Response.t()) ::
              map()

  @optional_callbacks model_metadata: 1,
                      estimate_cost: 2,
                      observe_stream: 3,
                      finish_stream: 3,
                      after_stream: 3,
                      annotate_message: 3

  @doc "Lists the models `route` can serve; see `c:available_models/2`."
  @spec available_models(route :: t(), opts :: keyword()) :: [String.t()]
  def available_models({module, state}, opts) when is_atom(module) and is_list(opts),
    do: module.available_models(state, opts)

  @doc "Returns optional model presentation metadata without affecting route selection."
  @spec model_metadata(route :: t()) :: %{optional(String.t()) => map()}
  def model_metadata({module, state}) when is_atom(module) do
    if implements?(module, :model_metadata, 1), do: module.model_metadata(state), else: %{}
  end

  @doc "Validates `model` with `tools` against `route`; see `c:validate_model/3`."
  @spec validate_model(route :: t(), model :: String.t(), tools :: [term()]) ::
          :ok | {:error, term()}
  def validate_model({module, state}, model, tools) when is_atom(module) and is_binary(model),
    do: module.validate_model(state, model, tools)

  @doc "The context window `route` reports for `model`; see `c:context_window/2`."
  @spec context_window(route :: t(), model :: String.t()) :: pos_integer() | nil
  def context_window({module, state}, model) when is_atom(module) and is_binary(model),
    do: module.context_window(state, model)

  @doc "The reasoning efforts `route` reports for `model`; see `c:reasoning_efforts/2`."
  @spec reasoning_efforts(route :: t(), model :: String.t()) :: [String.t()]
  def reasoning_efforts({module, state}, model) when is_atom(module) and is_binary(model),
    do: module.reasoning_efforts(state, model)

  @doc "Resolves the wire target for `request` through `route`; see `c:target/3`."
  @spec target(route :: t(), request :: Request.t(), options :: keyword()) ::
          {:ok, target()} | {:error, term()}
  def target({module, state}, %Request{} = request, options)
      when is_atom(module) and is_list(options),
      do: module.target(state, request, options)

  @doc "The route's cost estimate for `request`, or `nil` without a route or a callback."
  @spec estimate_cost(route :: t() | nil, request :: Request.t()) :: number() | nil
  def estimate_cost({module, state}, %Request{} = request) when is_atom(module) do
    if implements?(module, :estimate_cost, 2), do: module.estimate_cost(state, request)
  end

  def estimate_cost(nil, %Request{}), do: nil

  @doc "Lets `route` see a response before it is consumed; identity without one."
  @spec observe_stream(route :: t() | nil, response :: term(), reference :: reference()) :: term()
  def observe_stream({module, state}, response, reference)
      when is_atom(module) and is_reference(reference) do
    if implements?(module, :observe_stream, 3),
      do: module.observe_stream(state, response, reference),
      else: response
  end

  def observe_stream(nil, response, reference) when is_reference(reference), do: response

  @doc "Lets `route` finish a consumed result; identity without one."
  @spec finish_stream(route :: t() | nil, result :: term(), reference :: reference()) :: term()
  def finish_stream({module, state}, result, reference)
      when is_atom(module) and is_reference(reference) do
    if implements?(module, :finish_stream, 3),
      do: module.finish_stream(state, result, reference),
      else: result
  end

  def finish_stream(nil, result, reference) when is_reference(reference), do: result

  @doc "Lets a route start noncritical work after the terminal provider event."
  @spec after_stream(route :: t() | nil, request :: Request.t(), reference :: reference()) :: :ok
  def after_stream({module, state}, %Request{} = request, reference)
      when is_atom(module) and is_reference(reference) do
    if implements?(module, :after_stream, 3),
      do: module.after_stream(state, request, reference),
      else: :ok
  end

  def after_stream(nil, %Request{}, reference) when is_reference(reference), do: :ok

  @doc "Lets `route` add its own keys to an assistant message; identity without one."
  @spec annotate_message(route :: t() | nil, message :: map(), response :: term()) :: map()
  def annotate_message({module, state}, message, response)
      when is_atom(module) and is_map(message) do
    if implements?(module, :annotate_message, 3),
      do: module.annotate_message(state, message, response),
      else: message
  end

  def annotate_message(nil, message, _response) when is_map(message), do: message

  # `function_exported?/3` answers false for a module that has not been loaded
  # yet, and the optional hooks can be the first thing asked of a route in a
  # release that loads modules on demand.
  defp implements?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)
end
