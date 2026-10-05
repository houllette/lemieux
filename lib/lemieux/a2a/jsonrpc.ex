defmodule Lemieux.A2A.JSONRPC do
  @moduledoc """
  A2A 1.0 JSON-RPC envelopes. The host owns HTTP, authentication and the
  principal passed to `Lemieux.A2A.Handler`. Numeric errors follow the pinned
  specification, including its -32_001 through -32_009 registry.
  """
  alias Lemieux.A2A.Message
  alias Lemieux.A2A.Task

  @methods %{
    send_message: "SendMessage",
    send_streaming_message: "SendStreamingMessage",
    subscribe_to_task: "SubscribeToTask",
    get_task: "GetTask",
    cancel_task: "CancelTask",
    list_tasks: "ListTasks",
    get_extended_agent_card: "GetExtendedAgentCard",
    create_task_push_notification_config: "CreateTaskPushNotificationConfig",
    get_task_push_notification_config: "GetTaskPushNotificationConfig",
    list_task_push_notification_configs: "ListTaskPushNotificationConfigs",
    delete_task_push_notification_config: "DeleteTaskPushNotificationConfig"
  }
  @type method :: atom()
  @codes %{
    "ParseError" => -32_700,
    "InvalidRequest" => -32_600,
    "MethodNotFound" => -32_601,
    "InvalidParams" => -32_602,
    "InternalError" => -32_603,
    "TaskNotFound" => -32_001,
    "TaskNotCancelable" => -32_002,
    "PushNotificationNotSupported" => -32_003,
    "UnsupportedOperation" => -32_004,
    "ContentTypeNotSupported" => -32_005,
    "InvalidAgentResponse" => -32_006,
    "ExtendedAgentCardNotConfigured" => -32_007,
    "ExtensionSupportRequired" => -32_008,
    "VersionNotSupported" => -32_009
  }

  @doc """
  The wire name of an operation, such as `"SendMessage"` for `:send_message`.
  """
  @spec method(operation :: method()) :: String.t()
  def method(operation), do: Map.fetch!(@methods, operation)
  @doc "The operation a wire method name stands for, or `:error` for an unknown one."
  @spec from_method(name :: term()) :: {:ok, method()} | :error
  def from_method(name) do
    case Enum.find(@methods, fn {_key, wire} -> wire == name end) do
      {operation, _wire} -> {:ok, operation}
      nil -> :error
    end
  end

  @doc "A request envelope calling `method` with `params` under `id`."
  @spec request(method :: method(), params :: map(), id :: String.t()) :: map()
  def request(method, params, id),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method(method), "params" => params}

  @doc "A success envelope answering request `id`."
  @spec reply(id :: term(), result :: term()) :: map()
  def reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc """
  An error envelope answering request `id`.

  `name` is the A2A error name, such as `"TaskNotFound"`. Its numeric code comes
  from the specification's registry unless `code` is given; a name the registry
  does not have is an internal error (-32603).
  """
  @spec error(id :: term(), name :: String.t(), message :: String.t(), code :: integer() | nil) ::
          map()
  def error(id, name, message, code \\ nil) do
    reason = name |> String.replace(~r/([a-z])([A-Z])/, "\\1_\\2") |> String.upcase()

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code || Map.get(@codes, name, -32_603),
        "message" => message,
        "data" => [
          %{
            "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
            "reason" => reason,
            "domain" => "a2a-protocol.org",
            "metadata" => %{"name" => name}
          }
        ]
      }
    }
  end

  @doc "Encodes an envelope as JSON."
  @spec encode(envelope :: map()) :: binary()
  def encode(envelope), do: JSON.encode!(envelope)

  @doc """
  Decodes a JSON-RPC 2.0 envelope, or returns the `ParseError` or
  `InvalidRequest` envelope to send back instead.
  """
  @spec decode(body :: binary()) :: {:ok, map()} | {:error, map()}
  def decode(body) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0"} = envelope} -> {:ok, envelope}
      {:ok, _} -> {:error, error(nil, "InvalidRequest", "not a JSON-RPC 2.0 envelope")}
      {:error, _} -> {:error, error(nil, "ParseError", "invalid JSON")}
    end
  end

  @doc """
  The result a response envelope carries, or its error as a readable
  `"Name: message"` string. An envelope carrying both is refused as ambiguous.
  """
  @spec result(envelope :: term()) :: {:ok, term()} | {:error, String.t()}
  def result(%{"jsonrpc" => "2.0", "result" => result} = envelope) do
    if Map.has_key?(envelope, "error"),
      do: {:error, "ambiguous JSON-RPC response"},
      else: {:ok, result}
  end

  def result(%{"jsonrpc" => "2.0", "error" => %{"message" => message, "code" => code}})
      when is_binary(message) and is_integer(code) do
    name =
      Enum.find_value(@codes, "RPC error", fn {name, value} -> if value == code, do: name end)

    {:error, "#{name}: #{message}"}
  end

  def result(_envelope), do: {:error, "the response was neither a result nor an error"}

  @doc """
  Decodes `body`, checks its method and params, and calls `handler` with the
  operation and params.

  The handler returns `{:ok, result}` or `{:error, name, message}`; what this
  returns is the envelope to send, including for a body that never reached the
  handler.
  """
  @spec dispatch(body :: binary(), handler :: (method(), map() -> tuple())) :: map()
  def dispatch(body, handler) do
    case decode(body) do
      {:ok, envelope} -> perform(envelope, handler)
      {:error, failure} -> failure
    end
  end

  defp perform(%{"method" => name, "id" => id} = envelope, handler)
       when is_binary(name) and (is_binary(id) or is_integer(id)) do
    params = Map.get(envelope, "params", %{})

    with {:ok, operation} <- from_method(name),
         :ok <- validate_params(operation, params) do
      case handler.(operation, params) do
        {:ok, result} -> reply(id, result)
        {:error, error_name, message} -> error(id, error_name, message)
      end
    else
      :error -> error(id, "MethodNotFound", "unknown method")
      {:error, reason} -> error(id, "InvalidParams", reason)
    end
  end

  defp perform(envelope, _handler),
    do: error(envelope["id"], "InvalidRequest", "invalid method or id")

  @doc """
  Checks `params` against what the specification requires of `operation`: a
  well-formed message, a task id, or valid list filters and pagination.
  """
  @spec validate_params(operation :: method(), params :: term()) :: :ok | {:error, String.t()}
  def validate_params(operation, params) when is_map(params), do: parameters(operation, params)
  def validate_params(_operation, _params), do: {:error, "params must be an object"}

  defp parameters(operation, params) when operation in [:send_message, :send_streaming_message] do
    with :ok <- Message.validate(params["message"]),
         true <-
           Message.fields?(params, [{"configuration", &configuration?/1}, {"metadata", &is_map/1}]) do
      :ok
    else
      _ -> {:error, "invalid message or configuration"}
    end
  end

  defp parameters(operation, params)
       when operation in [:get_task, :cancel_task, :subscribe_to_task] do
    if is_binary(params["id"]) and params["id"] != "" and
         Message.optional?(params, "historyLength", &nonnegative?/1),
       do: :ok,
       else: {:error, "id and nonnegative historyLength required"}
  end

  defp parameters(:list_tasks, params) do
    fields = [
      {"pageSize", &(is_integer(&1) and &1 in 1..100)},
      {"pageToken", &(is_binary(&1) and byte_size(&1) <= 128)},
      {"historyLength", &nonnegative?/1},
      {"includeArtifacts", &is_boolean/1},
      {"statusTimestampAfter", &Message.timestamp?/1},
      {"contextId", &is_binary/1},
      {"status", &(Task.from_wire(&1) != :error)}
    ]

    if Message.fields?(params, fields),
      do: :ok,
      else: {:error, "invalid task filters or pagination"}
  end

  defp parameters(_operation, _params), do: :ok

  defp configuration?(config) when is_map(config) do
    Message.fields?(config, [
      {"returnImmediately", &is_boolean/1},
      {"historyLength", &nonnegative?/1},
      {"acceptedOutputModes", &Message.strings?/1}
    ])
  end

  defp configuration?(_config), do: false

  defp nonnegative?(value), do: is_integer(value) and value >= 0
end
