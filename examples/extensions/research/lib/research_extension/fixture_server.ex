defmodule ResearchExtension.FixtureServer do
  @moduledoc """
  Serves a directory of fixture pages on `127.0.0.1` for offline tests and
  benches, using OTP's `:httpd`.

  It exists because the fetch tool refuses loopback by default: the tests and
  the bench pass `unsafe_allow_loopback_for_tests: true` to
  `Lemieux.Tools.WebFetch.new/1` and point the static search index at this
  server's `base_url`. It is not part of the pipeline and a host never needs
  it.
  """

  @typedoc "A running server: its pid, port and the `http://127.0.0.1:PORT` base."
  @type t :: %{pid: pid(), port: pos_integer(), base_url: String.t()}

  @mime_types [
    {~c"html", ~c"text/html"},
    {~c"htm", ~c"text/html"},
    {~c"txt", ~c"text/plain"},
    {~c"md", ~c"text/markdown"},
    {~c"json", ~c"application/json"},
    {~c"xml", ~c"application/xml"},
    {~c"pdf", ~c"application/pdf"}
  ]

  @doc "Starts a server for `dir` on an ephemeral loopback port."
  @spec start(dir :: Path.t()) :: {:ok, t()} | {:error, term()}
  def start(dir) when is_binary(dir) do
    root = dir |> Path.expand() |> String.to_charlist()

    config = [
      port: 0,
      bind_address: {127, 0, 0, 1},
      server_name: ~c"fixtures",
      server_root: root,
      document_root: root,
      modules: [:mod_alias, :mod_get, :mod_head],
      mime_types: @mime_types
    ]

    # Under the inets supervisor rather than stand-alone: `:httpd.info/1`
    # only knows supervised services, and the port is assigned at bind time.
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, pid} <- :inets.start(:httpd, config) do
      port = Keyword.fetch!(:httpd.info(pid), :port)
      {:ok, %{pid: pid, port: port, base_url: "http://127.0.0.1:#{port}"}}
    end
  end

  @doc "Stops a server started by `start/1`."
  @spec stop(server :: t()) :: :ok
  def stop(%{pid: pid}), do: :inets.stop(:httpd, pid)
end
