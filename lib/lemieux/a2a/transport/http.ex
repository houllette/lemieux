defmodule Lemieux.A2A.Transport.HTTP do
  @moduledoc """
  Bounded A2A 1.0 JSON-RPC client. Strings become user Messages; SendMessage
  accepts the protocol's task/message union. `:stream` selects SSE and sends
  task snapshots/statuses and text deltas to a pid. `subscribe/3` reconnects
  to an existing task; writes are never retried automatically.

  All operations accept `:headers`, `:auth` (Req authentication), `:timeout`,
  `:max_response_bytes` and `:max_frame_bytes`. Redirects are disabled so an
  authenticated request cannot forward credentials to another origin. Endpoint
  URLs must have no userinfo, query or fragment. Cards are fetched from
  `/.well-known/agent-card.json`; `discover/2` selects a compatible JSONRPC
  interface. Callers decide whether they trust a discovered endpoint.
  """
  @behaviour Lemieux.A2A.Transport
  alias Lemieux.A2A.{Card, JSONRPC, Message, SSE}
  alias Lemieux.A2A.Task, as: A2ATask

  @impl Lemieux.A2A.Transport
  def handles?(url), do: valid_url?(url)

  @doc """
  Whether `url` is an endpoint this client calls: http or https, with a host and
  no userinfo, query or fragment.
  """
  @spec valid_url?(url :: term()) :: boolean()
  def valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} ->
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
          is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

      {:error, _reason} ->
        false
    end
  end

  def valid_url?(_url), do: false

  @impl Lemieux.A2A.Transport
  def send_message(url, message, opts \\ []) do
    message = Message.new(message)

    with :ok <- Message.validate(message) do
      params = %{"message" => message} |> configuration(opts)

      if is_pid(opts[:stream]),
        do: stream(url, :send_streaming_message, params, opts),
        else: unary_send(url, params, opts)
    end
  end

  @impl Lemieux.A2A.Transport
  def get_task(url, id), do: get_task(url, id, [])
  @spec get_task(url :: String.t(), id :: String.t(), opts :: keyword()) :: tuple()
  @impl Lemieux.A2A.Transport
  def get_task(url, id, opts),
    do:
      with(
        {:ok, json} <- call(url, :get_task, task_params(id, opts), opts),
        do: A2ATask.from_json(json)
      )

  @impl Lemieux.A2A.Transport
  def cancel_task(url, id), do: cancel_task(url, id, [])
  @spec cancel_task(url :: String.t(), id :: String.t(), opts :: keyword()) :: tuple()
  @impl Lemieux.A2A.Transport
  def cancel_task(url, id, opts),
    do:
      with(
        {:ok, json} <- call(url, :cancel_task, %{"id" => id}, opts),
        do: A2ATask.from_json(json)
      )

  @impl Lemieux.A2A.Transport
  def card(url), do: card(url, [])
  @spec card(url :: String.t(), opts :: keyword()) :: tuple()
  @impl Lemieux.A2A.Transport
  def card(url, opts) do
    uri = URI.parse(url)

    endpoint =
      URI.to_string(%{uri | path: "/.well-known/agent-card.json", query: nil, fragment: nil})

    with {:ok, body} <- request(endpoint, nil, opts),
         {:ok, json} <- decode_json(body),
         do: Card.from_json(json)
  end

  @doc """
  Fetches the agent card at `url` and selects its compatible JSON-RPC endpoint,
  returning both. Whether to trust a discovered endpoint is the caller's call.
  """
  @spec discover(url :: String.t(), opts :: keyword()) ::
          {:ok, Card.t(), String.t()} | {:error, String.t()}
  def discover(url, opts \\ []) do
    with {:ok, card} <- card(url, opts),
         {:ok, endpoint} <- Card.reachable(card, :jsonrpc),
         true <- valid_url?(endpoint) do
      {:ok, card, endpoint}
    else
      :error -> {:error, "card offers no compatible JSONRPC 1.0 interface"}
      false -> {:error, "card offers an invalid endpoint"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_tasks(url :: String.t(), params :: map(), opts :: keyword()) :: tuple()
  @impl Lemieux.A2A.Transport
  def list_tasks(url, params, opts \\ []), do: call(url, :list_tasks, params, opts)
  @spec subscribe(url :: String.t(), id :: String.t(), opts :: keyword()) :: tuple()
  @impl Lemieux.A2A.Transport
  def subscribe(url, id, opts \\ []), do: stream(url, :subscribe_to_task, %{"id" => id}, opts)

  defp configuration(params, opts) do
    config =
      opts
      |> Keyword.take([:return_immediately, :history_length])
      |> Map.new(fn
        {:return_immediately, value} -> {"returnImmediately", value}
        {:history_length, value} -> {"historyLength", value}
      end)

    Map.put(params, "configuration", config)
  end

  defp task_params(id, opts) do
    if Keyword.has_key?(opts, :history_length),
      do: %{"id" => id, "historyLength" => opts[:history_length]},
      else: %{"id" => id}
  end

  defp call(url, method, params, opts) do
    id = Lemieux.ID.generate()

    with {:ok, body} <- request(url, JSONRPC.encode(JSONRPC.request(method, params, id)), opts),
         {:ok, envelope} <- decode_rpc(body),
         :ok <- correlated(envelope, id),
         do: JSONRPC.result(envelope)
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      _ -> {:error, "agent sent invalid JSON"}
    end
  end

  defp decode_rpc(body) do
    case JSONRPC.decode(body) do
      {:ok, envelope} -> {:ok, envelope}
      _ -> {:error, "agent sent an invalid JSON-RPC envelope"}
    end
  end

  defp correlated(%{"id" => id}, id), do: :ok
  defp correlated(_envelope, _id), do: {:error, "JSON-RPC response id does not match request"}

  defp send_result(%{"task" => task} = result) when map_size(result) == 1,
    do: A2ATask.from_json(task)

  defp send_result(%{"message" => message} = result) when map_size(result) == 1 do
    with :ok <- Message.validate(message), do: {:ok, message}
  end

  defp send_result(_result), do: {:error, "invalid SendMessage task/message union"}

  defp request(url, body, opts) do
    max = Keyword.get(opts, :max_response_bytes, 2_000_000)

    into = fn {:data, chunk}, {req, resp} ->
      bytes = (resp.body || "") <> chunk

      if byte_size(bytes) > max,
        do: {:halt, {req, %{resp | body: {:error, :response_limit}}}},
        else: {:cont, {req, %{resp | body: bytes}}}
    end

    execute(url, body, opts, into, "application/json")
  end

  defp execute(url, body, opts, into, accept) do
    if valid_url?(url) do
      headers =
        Keyword.get(opts, :headers, []) ++
          [{"accept", accept}, {"a2a-version", "1.0"}, {"content-type", "application/json"}]

      options =
        [
          url: url,
          method: if(body, do: :post, else: :get),
          headers: headers,
          receive_timeout: Keyword.get(opts, :timeout, 180_000),
          retry: false,
          redirect: false,
          decode_body: false,
          into: into
        ] ++ Keyword.take(opts, [:auth])

      options = if body, do: Keyword.put(options, :body, body), else: options

      case bounded_request(options) do
        {:ok, %{body: {:error, reason}}} -> {:error, "response rejected: #{reason}"}
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status}} -> {:error, "agent answered HTTP #{status}"}
        {:error, _reason} -> {:error, "could not reach agent endpoint"}
      end
    else
      {:error, "invalid agent endpoint"}
    end
  end

  defp bounded_request(options) do
    timeout = Keyword.fetch!(options, :receive_timeout)
    task = Elixir.Task.async(fn -> Req.request(options) end)

    case Elixir.Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Elixir.Task.shutdown(task, :brutal_kill)
        {:error, :deadline}
    end
  end

  defp stream(url, method, params, opts) do
    id = Lemieux.ID.generate()
    max = Keyword.get(opts, :max_response_bytes, 2_000_000)
    frame_max = Keyword.get(opts, :max_frame_bytes, 256_000)

    into = fn {:data, chunk}, {req, resp} ->
      state = if is_map(resp.body), do: resp.body, else: %{buffer: "", bytes: 0, task: nil}

      with true <- state.bytes + byte_size(chunk) <= max,
           {:ok, buffer, frames} <- SSE.feed(state.buffer, chunk, frame_max),
           {:ok, task} <- consume(frames, state.task, id, opts[:stream]) do
        {:cont,
         {req,
          %{
            resp
            | body: %{state | buffer: buffer, bytes: state.bytes + byte_size(chunk), task: task}
          }}}
      else
        _ -> {:halt, {req, %{resp | body: {:error, :invalid_stream}}}}
      end
    end

    with {:ok, %{buffer: "", task: task}} <-
           execute(
             url,
             JSONRPC.encode(JSONRPC.request(method, params, id)),
             opts,
             into,
             "text/event-stream"
           ),
         true <-
           finished_response?(task) do
      {:ok, task}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error,
         "stream ended before a final or interrupted task status; retrieve or subscribe to the task"}
    end
  end

  defp unary_send(url, params, opts) do
    with {:ok, result} <- call(url, :send_message, params, opts), do: send_result(result)
  end

  defp consume(frames, task, id, watcher) do
    Enum.reduce_while(frames, {:ok, task}, fn envelope, {:ok, task} ->
      consume_frame(envelope, task, id, watcher)
    end)
  end

  defp finished_response?(%A2ATask{} = task),
    do: A2ATask.terminal?(task) or A2ATask.interrupted?(task)

  defp finished_response?(%{"messageId" => _id} = message), do: Message.validate(message) == :ok
  defp finished_response?(_response), do: false

  defp consume_frame(envelope, task, id, watcher) do
    with :ok <- correlated(envelope, id),
         {:ok, result} <- JSONRPC.result(envelope),
         {:ok, updated, event} <- update(result, task) do
      if is_pid(watcher), do: send(watcher, {:a2a, response_id(updated), event})
      {:cont, {:ok, updated}}
    else
      _ -> {:halt, {:error, :invalid_stream}}
    end
  end

  defp response_id(%A2ATask{id: id}), do: id
  defp response_id(message), do: message["taskId"] || message["messageId"]

  defp update(_result, %A2ATask{state: ending})
       when ending in [:completed, :failed, :canceled, :rejected, :input_required, :auth_required],
       do: {:error, :event_after_end}

  defp update(%{"message" => message} = result, nil) when map_size(result) == 1 do
    with :ok <- Message.validate(message), do: {:ok, message, {:message, message}}
  end

  defp update(%{"task" => json} = result, _task) when map_size(result) == 1 do
    with {:ok, task} <- A2ATask.from_json(json), do: {:ok, task, {:status, task}}
  end

  defp update(
         %{
           "statusUpdate" => %{"taskId" => id, "contextId" => context, "status" => status} = event
         } = result,
         %A2ATask{id: id, context_id: context} = task
       )
       when map_size(result) == 1 do
    with true <- Message.optional?(event, "metadata", &is_map/1),
         {:ok, updated} <-
           task |> A2ATask.to_json() |> Map.put("status", status) |> A2ATask.from_json() do
      updated = %{
        updated
        | metadata: Map.merge(updated.metadata, Map.get(event, "metadata", %{}))
      }

      {:ok, updated, {:status, updated}}
    else
      _ -> {:error, :invalid_status_update}
    end
  end

  defp update(
         %{
           "artifactUpdate" =>
             %{"taskId" => id, "contextId" => context, "artifact" => artifact} = event
         } = result,
         %A2ATask{id: id, context_id: context} = task
       )
       when map_size(result) == 1 do
    with true <- Message.fields?(event, [{"append", &is_boolean/1}, {"lastChunk", &is_boolean/1}]),
         {:ok, _validated} <-
           A2ATask.from_json(%{
             "id" => id,
             "status" => %{"state" => "TASK_STATE_WORKING"},
             "artifacts" => [artifact]
           }) do
      append_artifact(task, artifact, event["append"])
    else
      _ -> {:error, :invalid_artifact_update}
    end
  end

  defp update(_result, _task), do: {:error, :invalid_stream_event}

  defp append_artifact(task, artifact, append) do
    artifacts = A2ATask.artifacts(task)
    existing = Enum.find(artifacts, &(&1["artifactId"] == artifact["artifactId"]))

    combined =
      if append == true and existing,
        do: Map.put(artifact, "parts", existing["parts"] ++ artifact["parts"]),
        else: artifact

    artifacts =
      Enum.reject(artifacts, &(&1["artifactId"] == artifact["artifactId"])) ++ [combined]

    with {:ok, updated} <-
           task |> A2ATask.to_json() |> Map.put("artifacts", artifacts) |> A2ATask.from_json(),
         do:
           {:ok, updated,
            {:delta, Enum.map_join(artifact["parts"], "", &Map.get(&1, "text", ""))}}
  end
end
