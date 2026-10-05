defmodule LemieuxTest.HTTPAgent do
  @moduledoc """
  A minimal HTTP server, so the A2A HTTP binding can be tested over a socket.

  `Req` can be pointed at an in-process plug, but only if `plug` is a declared
  dependency — and adding a web-shaped dependency, even a test-only one, is
  the thing this project's rules say to think about rather than reach for. The
  alternative is about forty lines of `:gen_tcp`, and it buys something a stub
  cannot: the two properties most worth getting wrong in this binding are both
  properties of the wire.

  A JSON-RPC error arrives with HTTP **200** and lives in the body, so a client
  that reads the status to decide whether the call failed is wrong in a way an
  in-process double never reveals. And the agent card is served from
  `/.well-known/agent-card.json` rather than from the RPC endpoint, so a client that joins
  paths instead of replacing them asks for a URL that exists nowhere.

  It speaks exactly enough HTTP/1.1 to be answered by `Req`, and nothing more:
  no keep-alive, no chunking, no TLS.
  """

  @doc """
  Starts a server and returns its base URL.

  `handler` is called as `handler.(path, body)` and returns `{status, json}`.
  The server stops with the test that started it.
  """
  @spec start(handler :: (String.t(), binary() -> {non_neg_integer(), term()})) :: String.t()
  def start(handler) when is_function(handler, 2) or is_function(handler, 3) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    owner = self()

    spawn_link(fn ->
      # Linked to the test, so it dies with it and leaves no listener behind.
      Process.flag(:trap_exit, true)
      send(owner, :listening)

      accept(listen, handler)
    end)

    receive do
      :listening -> "http://127.0.0.1:#{port}"
    after
      5_000 -> raise "the test server never started listening"
    end
  end

  defp accept(listen, handler) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, handler) end)

        accept(listen, handler)

      {:error, :timeout} ->
        accept(listen, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, handler) do
    with {:ok, request} <- read_request(socket) do
      result =
        if is_function(handler, 3),
          do: handler.(request.path, request.body, request.headers),
          else: handler.(request.path, request.body)

      case result do
        {status, body} ->
          :gen_tcp.send(socket, response(status, JSON.encode!(body)))

        {status, content_type, chunks, delay} ->
          body = IO.iodata_to_binary(chunks)
          :gen_tcp.send(socket, response_head(status, byte_size(body), content_type))

          Enum.each(chunks, &send_chunk(socket, &1, delay))
      end
    end

    :gen_tcp.close(socket)
  end

  defp send_chunk(socket, chunk, delay) do
    :gen_tcp.send(socket, chunk)
    Process.sleep(delay)
  end

  # Headers first, then exactly `content-length` bytes of body — reading until
  # the socket closes would hang, because the client is waiting for a reply
  # before it closes anything.
  #
  # The body usually arrives in the *same* packet as the headers, so whatever
  # followed the blank line has to be carried forward. Dropping it and then
  # asking the socket for more is a five-second wait for bytes that already
  # arrived, ending in an empty body and a parse error blamed on the client.
  defp read_request(socket) do
    with {:ok, head, rest} <- read_head(socket, "") do
      [request_line | header_lines] = head |> String.split("\r\n") |> Enum.reject(&(&1 == ""))
      [_method, target | _version] = String.split(request_line, " ")
      headers = Map.new(header_lines, &header/1)
      length = headers |> Map.get("content-length", "0") |> String.to_integer()

      {:ok,
       %{path: URI.parse(target).path, headers: headers, body: read_body(socket, length, rest)}}
    end
  end

  defp read_head(socket, so_far) do
    if String.contains?(so_far, "\r\n\r\n") do
      [head, rest] = String.split(so_far, "\r\n\r\n", parts: 2)

      {:ok, head, rest}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, more} -> read_head(socket, so_far <> more)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_body(socket, length, so_far) when byte_size(so_far) < length do
    case :gen_tcp.recv(socket, length - byte_size(so_far), 5_000) do
      {:ok, more} -> so_far <> more
      {:error, _reason} -> so_far
    end
  end

  defp read_body(_socket, length, so_far), do: binary_part(so_far, 0, length)

  defp header(line) do
    [name, value] = String.split(line, ":", parts: 2)

    {name |> String.trim() |> String.downcase(), String.trim(value)}
  end

  defp response(status, body) do
    response_head(status, byte_size(body), "application/json") <> body
  end

  defp response_head(status, bytes, content_type) do
    "HTTP/1.1 #{status} #{reason(status)}\r\ncontent-type: #{content_type}\r\ncontent-length: #{bytes}\r\nconnection: close\r\n\r\n"
  end

  defp reason(200), do: "OK"
  defp reason(503), do: "Service Unavailable"
  defp reason(_status), do: "Status"
end
