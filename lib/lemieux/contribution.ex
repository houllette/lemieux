defmodule Lemieux.Contribution do
  @moduledoc """
  Namespaced, provider-free extension status and local commands.

  An extension appends these values to `Harness.contributions`. They belong to
  the current runtime, never to executable state reconstructed from a transcript.
  A namespace is unique within the session and never shadows a stock command.
  `commands` maps stable local names to `:observe` or `:cancel`; neither is an
  approval decision. Callback results are bounded status data, never session
  effects or instructions to execute. Network and billed work belong to separately
  declared tools/actions, not a status refresh. These are trusted host callbacks,
  so that contract is not a sandbox against arbitrary code in the same VM.

  `open/2` is optional. It receives `:lifecycle_owner`, an observer epoch guardian
  (not the session); an observer it starts must link to or monitor that owner
  immediately, including while startup is in progress. Return its PID and the
  runtime state subsequent callbacks use. The manager stops observers when the
  session closes or its effective environment changes. Callbacks run outside the
  session and UI, with a one-second deadline and a bounded pending queue.

  The context contains only current cwd, environment and opaque session id;
  no prompt, original-input capability, provider or session handle is supplied.
  Hosts choose which safe values to include in status. Do not return credentials,
  identities or raw command output. `message` is at most 256 UTF-8 bytes, `badge`
  32, and `pending` a nonnegative count. CLI and TUI share `format/1`.
  """
  @derive {Inspect, only: [:namespace, :module, :commands]}
  @enforce_keys [:namespace, :module, :state]
  defstruct @enforce_keys ++ [commands: %{}]
  @type t :: %__MODULE__{namespace: String.t(), module: module(), state: term(), commands: map()}
  @type status :: %{
          optional(:message) => String.t(),
          optional(:badge) => String.t(),
          optional(:pending) => non_neg_integer(),
          state: :ready | :pending | :unavailable | :error | :cancelled
        }
  @callback open(state :: term(), context :: map()) :: {:ok, term(), pid()} | {:error, term()}
  @callback status(state :: term(), context :: map()) :: status()
  @callback command(state :: term(), name :: String.t(), args :: String.t(), context :: map()) ::
              status()
  @optional_callbacks open: 2, command: 4

  @doc "Construct a contribution with stable namespace and local command kinds."
  @spec new!(namespace :: String.t(), module :: module(), state :: term(), opts :: keyword()) ::
          t()
  def new!(namespace, module, state, opts \\ []) do
    opts = Keyword.validate!(opts, [:commands])
    commands = Keyword.get(opts, :commands, %{})

    unless name?(namespace) and is_atom(module) and Code.ensure_loaded?(module) and
             function_exported?(module, :status, 2) and is_map(commands) and
             map_size(commands) <= 16 and
             Enum.all?(commands, fn {name, kind} ->
               name?(name) and kind in [:observe, :cancel]
             end),
           do:
             raise(
               ArgumentError,
               "invalid contribution namespace, callback or local command kind"
             )

    %__MODULE__{namespace: namespace, module: module, state: state, commands: commands}
  end

  @doc "Validate a session's finite registry, rejecting duplicate namespaces."
  @spec registry!(sources :: [t()]) :: [t()]
  def registry!(sources) when is_list(sources) and length(sources) <= 16 do
    names =
      Enum.map(sources, fn %__MODULE__{} = source ->
        new!(source.namespace, source.module, source.state, commands: source.commands).namespace
      end)

    if length(Enum.uniq(names)) != length(names),
      do: raise(ArgumentError, "duplicate contribution namespace")

    sources
  end

  def registry!(_invalid),
    do: raise(ArgumentError, "contributions require at most 16 registered sources")

  defp name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,47}\z/, name)

  @doc false
  @spec normalize(result :: term(), namespace :: String.t(), action :: atom()) ::
          {:ok, map()} | {:error, :invalid_status}
  def normalize(%{state: state} = result, namespace, action)
      when state in [:ready, :pending, :unavailable, :error, :cancelled] do
    if Enum.all?(Map.keys(result), &(&1 in [:state, :message, :badge, :pending])) and
         text?(Map.get(result, :message), 256) and text?(Map.get(result, :badge), 32) and
         count?(Map.get(result, :pending)) do
      {:ok,
       result
       |> Lemieux.Contract.json()
       |> Map.put("namespace", namespace)
       |> Map.put("action", Atom.to_string(action))}
    else
      {:error, :invalid_status}
    end
  end

  def normalize(_invalid, _namespace, _action), do: {:error, :invalid_status}
  defp text?(nil, _limit), do: true

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value)

  defp count?(nil), do: true
  defp count?(value), do: is_integer(value) and value in 0..1_000_000

  @doc "Render bounded structured status for a stock CLI or TUI receipt."
  @spec format(statuses :: [map()]) :: String.t()
  def format([]), do: "No extension status contributions."

  def format(statuses) do
    statuses
    |> Enum.take(16)
    |> Enum.map_join("\n", fn status ->
      line = "#{render_text(status["namespace"], 48)}: #{render_text(status["state"], 16)}"
      message = render_text(status["message"], 256)
      if message != "", do: line <> " — " <> message, else: line
    end)
  end

  defp render_text(value, limit) when is_binary(value) do
    value
    |> binary_part(0, min(byte_size(value), limit))
    |> valid_prefix()
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
  end

  defp render_text(_value, _limit), do: ""

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
