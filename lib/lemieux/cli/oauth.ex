defmodule Lemieux.CLI.OAuth do
  @moduledoc """
  `lmx`'s half of an MCP authorization flow: a browser and a socket.

  `Lemieux.MCP.Auth` does discovery, registration, PKCE, the exchange, storage
  and refresh. It cannot open a browser or bind a port, so this is what a host
  supplies — and it is deliberately all a host has to supply. An embedder
  writing its own version writes about this much.

  Three steps: listen on the loopback port the redirect URI names, ask the
  operating system to open the authorization URL, and wait for the browser to
  arrive at the callback with a query string.

  ## The port is fixed, and printed

  See `Lemieux.MCP.Auth.new/1` for why it is not ephemeral. What matters here
  is the consequence: the port is knowable in advance, so a person on a machine
  with no browser can forward it —

      ssh -L 8642:localhost:8642 devbox

  — run `lmx` on the far side, and click the printed link on the near side.
  That is the entire headless story, because there is no device-code flow in
  MCP to offer instead. The URL is therefore always written to stderr as well
  as handed to the browser: on a machine where nothing opens, the printed line
  is the flow rather than a diagnostic.

  ## Only loopback

  A redirect URI that is not `127.0.0.1` or `localhost` is refused rather than
  bound. Binding `0.0.0.0` so a remote browser can reach the callback directly
  is a real request — it is what Codex CLI allows and what Claude Code declined
  to add — but it puts an authorization code on the network, and `ssh -L`
  reaches the same place without doing that. If it is ever added it should be
  an explicit opt-in with the trade written next to it, not a consequence of
  somebody typing a hostname.

  ## Where the tokens are kept

  In `~/.lmx/mcp-credentials.json` (`default_store/0`) unless `--credentials`
  or `LMX_CREDENTIALS` names another file — beside the config file, the
  history and the transcripts, so everything `lmx` keeps for a person is in
  one directory and one sandbox rule hides all of it. Earlier builds used the
  library's default, `~/.lemieux/credentials.json` (`legacy_store/0`). The
  first time the default store is read or written, that file is moved across
  (`Lemieux.MCP.Auth.Store.File.migrate/2`) and it is not read again; a
  file named with `--credentials` or `LMX_CREDENTIALS` gets nothing moved
  into it. Moved, not copied: a copy is a second place the tokens can be
  read from, and one that brings them back after the new file is deleted to
  sign out. The old path is still the library's default for other hosts, so
  one on the same machine that never named a file of its own finds it gone
  and authorizes its servers again.
  """

  alias Lemieux.MCP.Auth.Store.File, as: FileStore

  @timeout :timer.minutes(3)

  @doc "Where `lmx` keeps MCP OAuth tokens when nothing names a file: `~/.lmx/mcp-credentials.json`."
  @spec default_store() :: Path.t()
  def default_store, do: Path.join([System.user_home!(), ".lmx", "mcp-credentials.json"])

  @doc "Where earlier builds of `lmx` kept them: the library's `~/.lemieux/credentials.json`."
  @spec legacy_store() :: Path.t()
  def legacy_store, do: FileStore.default_path()

  @page """
  <!doctype html><meta charset="utf-8"><title>lemieux</title>
  <body style="font: 16px/1.5 system-ui; margin: 4rem auto; max-width: 30rem">
  <h1>Authorized</h1><p>lemieux has the token. You can close this tab and go
  back to your terminal.</p>
  """

  @doc """
  Opens the authorization URL and waits for the redirect.

  Returns the redirect's query parameters, which is what
  `Lemieux.MCP.Auth` needs to finish the flow.

  ## Options

    * `:open` — how to open a URL, for tests. Defaults to the platform opener.
    * `:timeout` — how long to wait for somebody to finish, in milliseconds.
  """
  @spec redirect(url :: String.t(), redirect_uri :: String.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def redirect(url, redirect_uri, opts \\ []) do
    with {:ok, port} <- loopback_port(redirect_uri),
         {:ok, socket} <- listen(port) do
      try do
        announce(url)
        opener(opts).(url)

        accept(socket, Keyword.get(opts, :timeout, @timeout))
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp loopback_port(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{host: host, port: port} when host in ["127.0.0.1", "localhost", "::1"] ->
        {:ok, port}

      %URI{host: host} ->
        {:error,
         "the OAuth callback #{inspect(host)} is not a loopback address. lemieux only listens " <>
           "on 127.0.0.1; to authorize on a machine you are not sitting at, forward the port " <>
           "instead — ssh -L PORT:localhost:PORT — which keeps the authorization code off the " <>
           "network."}
    end
  end

  defp listen(port) do
    # `http_bin` so the kernel parses the request line rather than this module;
    # the only thing wanted from it is the path.
    options = [:binary, packet: :http_bin, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

    case :gen_tcp.listen(port, options) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :eaddrinuse} ->
        {:error,
         "something is already listening on port #{port}, so the OAuth callback cannot be " <>
           "received. Stop it, or choose another port with --oauth-callback-port."}

      {:error, reason} ->
        {:error, "could not listen on port #{port}: #{:inet.format_error(reason)}"}
    end
  end

  # Written to stderr rather than stdout so it never lands in the middle of a
  # piped transcript, and always — see the moduledoc.
  defp announce(url) do
    IO.puts(:stderr, "\nlmx: authorize this MCP server in your browser:\n  #{url}\n")
  end

  defp accept(socket, timeout) do
    case :gen_tcp.accept(socket, timeout) do
      {:ok, connection} ->
        serve(connection)

      {:error, :timeout} ->
        {:error, "no redirect arrived; nobody finished authorizing"}

      {:error, reason} ->
        {:error, "waiting for the redirect failed: #{:inet.format_error(reason)}"}
    end
  end

  defp serve(connection) do
    result = read_request(connection)

    # The browser is answered whatever happened, because a tab that hangs is
    # how somebody concludes the flow is broken when it worked.
    :gen_tcp.send(connection, response())
    :gen_tcp.close(connection)

    result
  end

  defp read_request(connection) do
    case :gen_tcp.recv(connection, 0, :timer.seconds(10)) do
      {:ok, {:http_request, _method, {:abs_path, path}, _version}} ->
        {:ok, query(path)}

      {:ok, other} ->
        {:error,
         "the callback received something that was not an HTTP request: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "reading the callback failed: #{:inet.format_error(reason)}"}
    end
  end

  defp query(path) do
    path
    |> to_string()
    |> URI.parse()
    |> Map.get(:query)
    |> case do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp response do
    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" <>
      "Content-Length: #{byte_size(@page)}\r\nConnection: close\r\n\r\n" <> @page
  end

  defp opener(opts), do: Keyword.get(opts, :open, &open/1)

  @doc """
  Asks the operating system to open a URL.

  A failure is deliberately not an error: the URL has already been printed, so
  a machine with nothing to open it with is a slower flow rather than a broken
  one.
  """
  @spec open(url :: String.t()) :: :ok
  def open(url) do
    case command() do
      {executable, args} -> System.cmd(executable, args ++ [url], stderr_to_stdout: true)
      nil -> :ok
    end

    :ok
  rescue
    # `System.cmd/3` raises when the executable is not there, which on a
    # headless box is the ordinary case rather than a fault.
    ErlangError -> :ok
  end

  defp command do
    cond do
      executable("open") -> {"open", []}
      executable("xdg-open") -> {"xdg-open", []}
      executable("rundll32") -> {"rundll32", ["url.dll,FileProtocolHandler"]}
      true -> nil
    end
  end

  defp executable(name), do: System.find_executable(name)
end
