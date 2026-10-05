defmodule LemieuxTest.HTTPFixture do
  @moduledoc false

  @spec server(handler :: function(), opts :: keyword()) :: {String.t(), port(), pid()}
  def server(handler, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    pid = spawn(fn -> serve(listener, handler, Keyword.get(opts, :requests, 1)) end)

    {"http://127.0.0.1:#{port}", listener, pid}
  end

  defp serve(_listener, _handler, 0), do: :ok

  defp serve(listener, handler, remaining) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 10_000) do
      {head, rest} = read_head(socket, "")
      headers = headers(head)
      body = read_body(socket, rest, String.to_integer(headers["content-length"] || "0"))
      send_response(socket, invoke(handler, head, headers, body, socket))
      :gen_tcp.close(socket)
      serve(listener, handler, remaining - 1)
    end
  end

  defp invoke(handler, head, headers, body, socket) when is_function(handler, 4) do
    [request_line | _] = String.split(head, "\r\n")
    [_method, path, _version] = String.split(request_line, " ")
    handler.(path, headers, body, socket)
  end

  defp invoke(handler, _head, headers, body, socket), do: handler.(headers, body, socket)

  defp headers(head) do
    [_ | lines] = String.split(head, "\r\n")

    Map.new(lines, fn line ->
      [key, value] = String.split(line, ":", parts: 2)
      {String.downcase(key), String.trim(value)}
    end)
  end

  defp send_response(_socket, :sent), do: :ok

  defp send_response(socket, response) do
    content_type =
      List.keyfind(response.headers, "content-type", 0, {nil, "application/json"}) |> elem(1)

    headers =
      for {name, value} <- response.headers,
          name != "content-type",
          do: [name, ": ", value, "\r\n"]

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{response.status} OK\r\ncontent-type: #{content_type}\r\n",
      headers,
      "content-length: #{byte_size(response.body)}\r\nconnection: close\r\n\r\n",
      response.body
    ])
  end

  defp read_head(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 10_000)
        read_head(socket, acc <> bytes)
    end
  end

  defp read_body(_socket, acc, length) when byte_size(acc) >= length, do: acc

  defp read_body(socket, acc, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, length - byte_size(acc), 10_000)
    read_body(socket, acc <> bytes, length)
  end
end
