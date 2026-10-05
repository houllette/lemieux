defmodule Lemieux.A2A.Handler do
  @moduledoc """
  Host adapter for authenticated A2A 1.0 JSON-RPC. Call after authenticating
  HTTP and pass `principal: stable_identity`, `server: pid_or_name` and the
  `:version` header. The host owns HTTP status, body limits, TLS, cancellation
  of disconnected streams and admission across server instances.

  `dispatch/2` handles unary operations. `open_stream/2` returns an initial
  envelope; the host writes it as SSE, then forwards `{:a2a, id, event}` with
  `SSE.event/3`. Both are synchronous preparation only, no HTTP dependency.
  `close_stream/2` removes a subscription when the HTTP client disconnects.
  """
  alias Lemieux.A2A.{Card, JSONRPC, Server, Task}

  @doc """
  Answers one unary JSON-RPC request body with the response envelope to encode.

  Requires `:principal`, the authenticated caller's stable identity. `:server`
  names the server to call (`Lemieux.A2A.Server` by default), and a
  `:version` other than `"1.0"` is refused. Streaming methods are refused here
  and go through `open_stream/2`.
  """
  @spec dispatch(body :: binary(), opts :: keyword()) :: map()
  def dispatch(body, opts) do
    JSONRPC.dispatch(body, fn operation, params ->
      with :ok <- authorized(opts), :ok <- version(opts) do
        perform(operation, params, opts)
      end
    end)
  end

  @doc """
  Starts `SendStreamingMessage` or `SubscribeToTask` for the calling process and
  returns the envelope to write as the stream's first frame.

  Later updates arrive in the caller's mailbox as `{:a2a, id, event}`; write
  each with `Lemieux.A2A.SSE.event/3`. Takes the options `dispatch/2` takes.
  """
  @spec open_stream(body :: binary(), opts :: keyword()) :: map()
  def open_stream(body, opts) do
    JSONRPC.dispatch(body, fn operation, params ->
      with :ok <- authorized(opts), :ok <- version(opts) do
        streaming(operation, params, opts)
      end
    end)
  end

  defp streaming(:send_streaming_message, params, opts) do
    params =
      Map.update(
        params,
        "configuration",
        %{"returnImmediately" => true},
        &Map.put(&1, "returnImmediately", true)
      )

    perform(:send_message, params, Keyword.put(opts, :stream, self()))
  end

  defp streaming(:subscribe_to_task, params, opts) do
    case Server.request(:subscribe_to_task, params, Keyword.put(opts, :stream, self())) do
      {:ok, task} -> {:ok, %{"task" => Task.to_json(task)}}
      result -> result
    end
  end

  defp streaming(_operation, _params, _opts),
    do: {:error, "UnsupportedOperation", "use a streaming method"}

  @doc """
  Removes the calling process's subscription to task `id`, for when the HTTP
  client disconnects. Takes the options `dispatch/2` takes.
  """
  @spec close_stream(id :: String.t(), opts :: keyword()) :: tuple()
  def close_stream(id, opts),
    do: Server.request(:unsubscribe, %{"id" => id}, Keyword.put(opts, :stream, self()))

  defp perform(:get_extended_agent_card, _params, _opts),
    do: {:error, "ExtendedAgentCardNotConfigured", "no extended card configured"}

  defp perform(operation, _params, _opts)
       when operation in [:send_streaming_message, :subscribe_to_task],
       do: {:error, "UnsupportedOperation", "use open_stream for SSE"}

  defp perform(operation, _params, _opts)
       when operation in [
              :create_task_push_notification_config,
              :get_task_push_notification_config,
              :list_task_push_notification_configs,
              :delete_task_push_notification_config
            ],
       do: {:error, "PushNotificationNotSupported", "use task streaming"}

  defp perform(operation, params, opts) do
    case Server.request(operation, params, opts) do
      {:ok, %Task{} = task} when operation == :send_message ->
        {:ok, %{"task" => Task.to_json(task)}}

      {:ok, %Task{} = task} ->
        {:ok, Task.to_json(task)}

      {:ok, %Card{} = card} ->
        {:ok, Card.to_json(card)}

      result ->
        result
    end
  end

  defp authorized(opts) do
    if is_binary(opts[:principal]) and opts[:principal] != "",
      do: :ok,
      else: {:error, "InvalidRequest", "host authentication required"}
  end

  defp version(opts) do
    if Keyword.get(opts, :version, "1.0") == "1.0",
      do: :ok,
      else: {:error, "VersionNotSupported", "this agent supports A2A 1.0"}
  end
end
