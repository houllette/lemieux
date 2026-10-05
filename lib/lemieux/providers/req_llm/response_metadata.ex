defmodule Lemieux.Providers.ReqLLM.ResponseMetadata do
  @moduledoc false

  alias ReqLLM.StreamResponse.MetadataHandle

  @private_headers ~w(x-ixway-key x-ixway-receipt-url x-ixway-receipt-token)

  # process_stream closes its metadata handle before returning, including on
  # errors. A forwarding handle lets us observe the public metadata once,
  # without another stream consumer, Finch internals or global telemetry.
  @spec capture(
          response :: ReqLLM.StreamResponse.t(),
          options :: map(),
          consume :: function()
        ) ::
          {term(), map()}
  def capture(response, options, consume) do
    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        MetadataHandle.await(response.metadata_handle)
      end)

    try do
      result = consume.(%{response | metadata_handle: handle})
      {result, select(available_metadata(response.metadata_handle), options)}
    after
      MetadataHandle.stop(handle)
      # The caller deadline can expire while HTTP keepalives keep transport
      # alive. Cleanup must run even when metadata or callbacks fail.
      response.cancel.()
    end
  end

  # On a caller-only timeout the server may still be running. Never wait for
  # its full metadata deadline; allow a bounded drain of a terminal server's
  # already pending reply, then report unknown fields and close the transport.
  defp available_metadata(handle) do
    MetadataHandle.await(handle, 50)
  catch
    :exit, {:timeout, _} -> %{}
    :exit, {:noproc, _} -> %{}
  end

  @spec event(
          request :: Lemieux.Request.t(),
          metadata :: map(),
          result :: term(),
          options :: map()
        ) ::
          {:response_metadata, map()}
  def event(request, metadata, result, options) do
    fallback = error_metadata(result, options)

    metadata =
      Map.merge(fallback, Map.reject(metadata, fn {_key, value} -> value in [nil, %{}] end))

    {:response_metadata,
     %{
       request_id: request.context[:request_id],
       requested_model: request.model,
       resolved_model: metadata[:resolved_model],
       status: metadata[:status],
       headers: metadata[:headers] || %{}
     }}
  end

  @spec options!(options :: keyword()) :: map()
  def options!(options) do
    options = Keyword.validate!(options, headers: [], model_header: nil)
    headers = headers!(options[:headers])
    model_header = options[:model_header]
    model_header = if model_header, do: hd(headers!([model_header]))

    %{
      headers: Enum.reject(headers, &(&1 in @private_headers)),
      model_header: private_model(model_header)
    }
  end

  defp private_model(header) when header in @private_headers, do: nil
  defp private_model(header), do: header

  defp headers!(headers) do
    unless is_list(headers) and
             Enum.all?(
               headers,
               &(is_binary(&1) and Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, &1))
             ) do
      raise ArgumentError, ":response_metadata headers must be HTTP header names"
    end

    headers |> Enum.map(&String.downcase/1) |> Enum.uniq()
  end

  defp select(metadata, options) do
    headers = metadata[:headers] || []
    model = select_headers(headers, [options.model_header])[options.model_header]

    %{
      status: metadata[:status],
      resolved_model: if(model, do: List.first(model)),
      headers: select_headers(headers, options.headers)
    }
  end

  defp error_metadata({:error, %{status: status, headers: headers}}, options)
       when is_integer(status),
       do: select(%{status: status, headers: headers}, options)

  defp error_metadata({:error, %{cause: cause}}, options) when not is_nil(cause),
    do: error_metadata({:error, cause}, options)

  defp error_metadata(_result, _allowed), do: %{}

  defp select_headers(headers, allowed) do
    Enum.reduce(headers, %{}, fn {name, values}, acc ->
      name = String.downcase(name)

      if name in allowed,
        do: Map.update(acc, name, List.wrap(values), &(&1 ++ List.wrap(values))),
        else: acc
    end)
  end
end
