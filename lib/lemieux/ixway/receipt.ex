defmodule Lemieux.Ixway.Receipt do
  @moduledoc """
  Private, best-effort reconciliation for the optional Ixway route.

  The stream hook keeps the receipt token in the provider task's mailbox until
  the answer is complete. This module then reads only the key-owned receipt's
  `data.api_equivalent`, and sends a small validated comparison to the session.
  It never changes usage, cost, admission or the transcript. The comparison
  uses the gateway's currently installed API catalog, so a later read can
  produce a different estimate for the same settled request.
  """

  @attempts 3
  @timeout_ms 2_000
  @default_retry_ms 250
  @max_retry_ms 2_000
  @header_names ~w(x-ixway-request-id x-ixway-receipt-url x-ixway-receipt-token)

  @doc false
  @spec headers([{String.t(), term()}]) :: map()
  def headers(headers) do
    Map.new(
      for {name, value} <- headers,
          name = String.downcase(name),
          name in @header_names,
          value = first(value),
          is_binary(value),
          do: {name, value}
    )
  end

  @doc false
  @spec start(Lemieux.Ixway.t(), map(), map()) :: :ok
  def start(connection, headers, %{route_result_sink: sink, request_id: request_id} = context)
      when is_pid(sink) and is_binary(request_id) do
    case receipt_credentials(headers) do
      {:ok, id, url, token} -> start_lookup(connection, context, id, url, token)
      :missing -> notify_unknown(sink, request_id, "receipt_metadata_missing")
      :none -> :ok
    end

    :ok
  end

  def start(_connection, _headers, _context), do: :ok

  defp receipt_credentials(%{
         "x-ixway-request-id" => id,
         "x-ixway-receipt-url" => url,
         "x-ixway-receipt-token" => token
       })
       when is_binary(id) and is_binary(url) and is_binary(token),
       do: {:ok, id, url, token}

  defp receipt_credentials(%{"x-ixway-receipt-url" => _}), do: :missing
  defp receipt_credentials(%{"x-ixway-receipt-token" => _}), do: :missing
  defp receipt_credentials(_headers), do: :none

  defp start_lookup(
         connection,
         %{route_result_sink: sink, request_id: request_id} = context,
         id,
         url,
         token
       ) do
    # A receipt may settle after the provider task exits. This independent,
    # bounded task must never hold the streamed answer open.
    task = fn ->
      case safe_lookup(connection, id, url, token) do
        :absent -> :ok
        comparison -> send(sink, {:route_observation, request_id, observation(comparison)})
      end
    end

    case start_task(context, task) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> notify_unknown(sink, request_id, "receipt_unavailable")
    end
  end

  defp notify_unknown(sink, request_id, reason) do
    send(sink, {:route_observation, request_id, observation(unknown(reason))})
  end

  defp start_task(context, task) do
    case Map.get(context, :route_task_supervisor) do
      nil -> Task.start(task)
      supervisor -> Task.Supervisor.start_child(supervisor, task)
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_lookup(connection, id, url, token) do
    lookup(connection, id, url, token)
  rescue
    _error -> unknown("receipt_unavailable")
  catch
    :exit, _reason -> unknown("receipt_unavailable")
  end

  defp lookup(connection, id, url, token) do
    case receipt_path(connection.endpoint, id, url) do
      {:ok, path} -> fetch(connection, path, token, @attempts)
      :error -> unknown("invalid_receipt_url")
    end
  end

  defp receipt_path(endpoint, id, url) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id),
      do: validate_receipt_url(endpoint, "/v1/ixway/requests/" <> id, url),
      else: :error
  end

  defp validate_receipt_url(endpoint, path, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: nil, host: nil, path: ^path, query: nil, fragment: nil}} ->
        {:ok, path}

      {:ok, %URI{path: ^path, userinfo: nil, query: nil, fragment: nil} = receipt} ->
        if same_origin?(receipt, URI.parse(endpoint)), do: {:ok, path}, else: :error

      _ ->
        :error
    end
  end

  defp same_origin?(receipt, origin),
    do:
      receipt.scheme == origin.scheme and receipt.host == origin.host and
        port(receipt) == port(origin)

  defp port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp port(%URI{port: port}), do: port

  defp fetch(connection, path, token, remaining) do
    options = [
      url: connection.endpoint <> path,
      headers: [{"x-ixway-key", connection.api_key}, {"x-ixway-receipt-token", token}],
      redirect: false,
      retry: false,
      request_timeout: @timeout_ms,
      receive_timeout: @timeout_ms
    ]

    # HTTP failures can include the request in their exception data. Translate
    # them here without logging or forwarding either credential.
    response =
      try do
        Req.get(options)
      rescue
        _error -> {:error, :unavailable}
      catch
        :exit, _reason -> {:error, :unavailable}
      end

    handle_response(response, connection, path, token, remaining)
  end

  defp handle_response(
         {:ok, %{status: 200, body: %{"data" => data}}},
         connection,
         _path,
         token,
         _remaining
       ),
       do: data |> estimate() |> private_check([connection.api_key, token])

  defp handle_response({:ok, %{status: 200}}, _connection, _path, _token, _remaining),
    do: unknown("invalid_receipt")

  defp handle_response({:ok, %{status: 202} = pending}, connection, path, token, remaining)
       when remaining > 1 do
    Process.sleep(retry_after(pending))
    fetch(connection, path, token, remaining - 1)
  end

  defp handle_response({:ok, %{status: 202}}, _connection, _path, _token, _remaining),
    do: unknown("settlement_pending")

  defp handle_response({:ok, %{status: 404}}, _connection, _path, _token, _remaining),
    do: unknown("receipt_not_found")

  defp handle_response({:ok, %{status: status}}, _connection, _path, _token, _remaining)
       when is_integer(status),
       do: unknown("receipt_http_#{status}")

  defp handle_response({:error, error}, _connection, _path, _token, _remaining),
    do: unknown(if(timeout?(error), do: "receipt_timeout", else: "receipt_unavailable"))

  defp retry_after(response) do
    case response |> Req.Response.get_header("retry-after") |> List.first() do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, @max_retry_ms)
          _ -> @default_retry_ms
        end

      _ ->
        @default_retry_ms
    end
  end

  defp timeout?(%{reason: reason}) when reason in [:timeout, :recv_timeout], do: true
  defp timeout?(_error), do: false

  defp estimate(%{"api_equivalent" => %{"state" => "estimated"} = value}) do
    amount = value["amount"]
    provider = value["reference_provider"]
    source = value["reference_source"]
    excludes = value["excludes"]

    if valid_base?(value) and valid_amount?(amount) and safe_label?(provider) and
         safe_source?(source) and valid_excludes?(excludes) do
      %{
        "state" => "estimated",
        "amount" => amount,
        "reference_provider" => provider,
        "reference_source" => source,
        "excludes" => excludes
      }
    else
      unknown("invalid_estimate")
    end
  end

  defp estimate(%{"api_equivalent" => %{"state" => "unknown"} = value}) do
    reason = value["reason"]

    if valid_base?(value) and is_nil(value["amount"]) and safe_reason?(reason) and
         valid_excludes?(value["excludes"]) do
      unknown(reason)
      |> Map.put("reference_provider", optional_label(value["reference_provider"]))
      |> Map.put("reference_source", optional_source(value["reference_source"]))
      |> Map.put("excludes", value["excludes"])
    else
      unknown("invalid_estimate")
    end
  end

  defp estimate(%{"api_equivalent" => _value}), do: unknown("invalid_estimate")
  defp estimate(%{}), do: :absent
  defp estimate(_data), do: unknown("invalid_receipt")

  defp private_check(:absent, _secrets), do: :absent

  defp private_check(comparison, secrets) do
    values = [
      comparison["amount"],
      comparison["reason"],
      comparison["reference_provider"],
      comparison["reference_source"]
      | comparison["excludes"]
    ]

    if Enum.any?(secrets, fn secret ->
         is_binary(secret) and secret != "" and
           Enum.any?(values, &(is_binary(&1) and String.contains?(&1, secret)))
       end),
       do: unknown("invalid_estimate"),
       else: comparison
  end

  defp valid_base?(%{
         "currency" => "USD",
         "basis" => "api_catalog_token_equivalent",
         "billed" => false
       }),
       do: true

  defp valid_base?(_value), do: false

  defp valid_amount?(amount) when is_binary(amount) and byte_size(amount) <= 64,
    do: Regex.match?(~r/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/, amount)

  defp valid_amount?(_amount), do: false

  defp valid_excludes?(values) when is_list(values) and length(values) <= 8,
    do: Enum.all?(values, &safe_reason?/1)

  defp valid_excludes?(_values), do: false

  defp safe_reason?(value) when is_binary(value) and byte_size(value) in 1..100,
    do: Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, value)

  defp safe_reason?(_value), do: false

  defp safe_label?(value) when is_binary(value) and byte_size(value) in 1..160,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@#-]*\z/, value)

  defp safe_label?(_value), do: false

  # Ixway's source is a space-separated catalog identity: "llm_db VERSION
  # PROVIDER/MODEL DIGEST". Keep each token display-safe without rejecting
  # the spaces that are part of the actual receipt contract.
  defp safe_source?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: value |> String.split(" ", trim: false) |> Enum.all?(&safe_label?/1)

  defp safe_source?(_value), do: false

  defp optional_label(nil), do: nil
  defp optional_label(value), do: if(safe_label?(value), do: value)

  defp optional_source(nil), do: nil
  defp optional_source(value), do: if(safe_source?(value), do: value)

  defp unknown(reason) do
    %{
      "state" => "unknown",
      "amount" => nil,
      "reason" => reason,
      "reference_provider" => nil,
      "reference_source" => nil,
      "excludes" => []
    }
  end

  defp observation(comparison) do
    %{"kind" => "ixway_api_equivalent", "data" => comparison, "text" => format(comparison)}
  end

  defp format(%{"state" => "estimated"} = comparison) do
    source = "#{comparison["reference_provider"]} / #{comparison["reference_source"]}"

    "API equivalent estimate: $#{comparison["amount"]} USD · #{source}" <>
      exclusions(comparison) <>
      " · illustrative at current catalog rates; may change when the catalog changes"
  end

  defp format(%{"state" => "unknown"} = comparison) do
    source =
      case {comparison["reference_provider"], comparison["reference_source"]} do
        {provider, source} when is_binary(provider) and is_binary(source) ->
          " · #{provider} / #{source}"

        _ ->
          ""
      end

    "API equivalent estimate: unknown (#{comparison["reason"]})#{source}" <>
      exclusions(comparison)
  end

  defp exclusions(%{"excludes" => [_ | _] = values}),
    do: " · excludes " <> Enum.map_join(values, ", ", &String.replace(&1, "_", " "))

  defp exclusions(_comparison), do: ""

  defp first([value | _]), do: value
  defp first(value), do: value
end
