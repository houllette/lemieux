defmodule Lemieux.Input.Capture do
  @moduledoc false
  @derive {Inspect, only: []}
  defstruct [:id, :token, :text, :expires, :timer]
end

defmodule Lemieux.Input do
  @moduledoc """
  Ephemeral current-input provenance in native hook context.

  `context.current_input` carries version, input/run/session correlation,
  source, attestor references and a `transformed?` flag. Legacy prompts have
  source `:unknown`. Queued follow-ups, steering, asides, extension feedback
  and resumed history retain their operational classification; they never
  become fresh direct input because a transcript says `user`.

  Hosts install `:ingress` (`Lemieux.Ingress`) and submit an untrusted claim
  using `Session.prompt/3` or `Session.follow_up/3`. Provenance grants no
  permission. Clients cannot install an attestor through input options.

  Original bytes are absent by default. With `:input_capture_bytes` (at most
  1 MiB), native hooks receive `context.input_original`, an opaque capability
  accepted by `original/1`. Capture is all-or-nothing and expires at run end,
  cancellation or `:input_capture_ttl_ms` (at most one minute). It is not
  copied into transcripts, telemetry, status or command-hook input. A rewrite
  keeps the original provenance and marks subsequent hook contexts changed.
  """

  alias Lemieux.Clock
  alias Lemieux.Ingress

  @type capability :: {pid(), String.t(), reference()} | nil
  @type t :: map()

  @doc "Reads explicitly captured original bytes while the live capability is valid."
  @spec original(capability :: capability()) :: {:ok, String.t()} | {:error, :unavailable}
  def original({session, id, token})
      when is_pid(session) and is_binary(id) and is_reference(token) do
    GenServer.call(session, {:input_original, id, token})
  catch
    :exit, _gone -> {:error, :unavailable}
  end

  def original(_unavailable), do: {:error, :unavailable}

  @doc false
  @spec options(opts :: keyword()) :: map()
  def options(opts) do
    %{
      ingress: Ingress.option(opts[:ingress]),
      capture_bytes: bounded!(opts, :input_capture_bytes, 0, 0, 1_048_576),
      capture_ttl_ms: bounded!(opts, :input_capture_ttl_ms, 60_000, 1, 60_000),
      current: nil,
      capture: nil
    }
  end

  defp bounded!(opts, key, default, low, high) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= low and value <= high,
      do: value,
      else: raise(ArgumentError, "#{key} must be an integer between #{low} and #{high}")
  end

  @doc false
  @spec attest(state :: map(), from :: GenServer.from(), kind :: atom(), opts :: keyword()) ::
          {:ok, map()} | {:error, atom()}
  def attest(state, {caller, _tag}, kind, opts) do
    if Keyword.keys(opts) -- [:attestation] == [],
      do:
        Ingress.attest(state.input.ingress, caller, :input, opts[:attestation], %{
          kind: kind,
          session_id: state.id
        }),
      else: {:error, :invalid_input_options}
  end

  @doc false
  @spec begin(state :: map(), source :: atom(), text :: String.t(), attestation :: map()) :: map()
  def begin(state, source, text, attestation \\ Ingress.unknown()) do
    state = clear(state)
    id = "input_" <> Lemieux.ID.generate()

    run_id =
      case state.evidence.current_run do
        %{id: run_id} ->
          run_id

        nil ->
          if state.evidence.run_sequence == 0,
            do:
              Map.get(state.evidence.correlation_ids, "run_id") || "run_" <> Lemieux.ID.generate(),
            else: "run_" <> Lemieux.ID.generate()
      end

    source = if source == :prompt, do: attestation.source, else: source

    current =
      Map.merge(attestation, %{
        input_id: id,
        session_id: state.id,
        run_id: run_id,
        source: source,
        transformed?: false
      })

    capture =
      if state.input.capture_bytes > 0 and byte_size(text) <= state.input.capture_bytes,
        do: capture(state, id, text),
        else: nil

    %{state | input: %{state.input | current: current, capture: capture}}
  end

  @doc false
  @spec clear(state :: map()) :: map()
  def clear(state) do
    if state.input.capture, do: Clock.cancel(state.clock, state.input.capture.timer)
    %{state | input: %{state.input | current: nil, capture: nil}}
  end

  defp capture(state, id, text) do
    token = make_ref()

    %Lemieux.Input.Capture{
      id: id,
      token: token,
      text: text,
      expires: Clock.now_ms(state.clock) + state.input.capture_ttl_ms,
      timer:
        Clock.send_after(
          state.clock,
          self(),
          {:input_expired, id, token},
          state.input.capture_ttl_ms
        )
    }
  end

  @doc false
  @spec expire(state :: map(), id :: String.t(), token :: reference()) :: map()
  def expire(%{input: %{capture: %{id: id, token: token}}} = state, id, token),
    do: put_in(state.input.capture, nil)

  def expire(state, _id, _token), do: state

  @doc false
  @spec transformed(state :: map(), original :: String.t(), effective :: String.t()) :: map()
  def transformed(%{input: %{current: nil}} = state, _original, _effective), do: state

  def transformed(state, original, effective),
    do:
      put_in(
        state.input.current.transformed?,
        state.input.current.transformed? or original != effective
      )

  @doc false
  @spec context(state :: map()) :: map()
  def context(state) do
    capability =
      case state.input.capture do
        %{id: id, token: token, expires: expires} ->
          if Clock.now_ms(state.clock) < expires, do: {self(), id, token}, else: nil

        nil ->
          nil
      end

    %{current_input: state.input.current, input_original: capability}
  end

  @doc false
  @spec read(state :: map(), id :: String.t(), token :: reference()) ::
          {:ok, String.t()} | {:error, :unavailable}
  def read(
        %{input: %{capture: %{id: id, token: token, expires: expires, text: text}}} = state,
        id,
        token
      ) do
    if Clock.now_ms(state.clock) < expires, do: {:ok, text}, else: {:error, :unavailable}
  end

  def read(_state, _id, _token), do: {:error, :unavailable}

  @doc false
  @spec queued_text(submission :: String.t() | {String.t(), map()}) :: String.t()
  def queued_text({text, _attestation}), do: text
  def queued_text(text) when is_binary(text), do: text

  @doc false
  @spec hook_context(context :: map(), original :: String.t(), effective :: String.t()) :: map()
  def hook_context(%{current_input: %{} = input} = context, original, effective),
    do: %{
      context
      | current_input: %{input | transformed?: input.transformed? or original != effective}
    }

  def hook_context(context, _original, _effective), do: context
end
