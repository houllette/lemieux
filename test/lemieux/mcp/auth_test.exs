defmodule Lemieux.MCP.AuthTest do
  @moduledoc """
  The whole flow, against a fixture that is a real OAuth 2.1 authorization
  server on a real socket.

  The fixture is strict about what a client is *required* to send — PKCE with
  S256, the `resource` parameter on both requests, `state`, and a `redirect_uri`
  on the token request matching the one the code was authorized for. So a
  client that stops sending one fails here, rather than months later against
  somebody else's server.

  There is no browser: the `redirect` seam is a function, and the test's
  implementation of it fetches the authorization URL and reads the `Location`
  header, which is what a browser would have followed.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lemieux.MCP
  alias Lemieux.MCP.Auth
  alias Lemieux.MCP.Auth.Store
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.Transport.HTTP
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Result

  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    %{
      port: free_port(),
      store: Store.File.new(Path.join(tmp_dir, "credentials.json"))
    }
  end

  # Scheduler-local unique integers can collide after they are folded into a
  # small port range. The kernel is the authority on which loopback port is
  # actually free.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp serve(mode, port, attempts \\ 3) do
    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :hide,
        line: 1024,
        args: [@fixture, mode, "--http", to_string(port)]
      ])

    {:os_pid, os_pid} = Port.info(server, :os_pid)

    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true) end)

    case await_listening(port, server) do
      :ok ->
        :ok

      # `free_port/0` names a port by binding one and letting go, so between
      # that and the fixture binding it, anything on the machine can take it —
      # most often another case here doing the same thing. The fixture then
      # exits instead of listening, and no amount of waiting fixes a port
      # nothing will ever answer on. The squatter is transient, so trying
      # again is enough; waiting was not, at eight seconds.
      {:error, :exited} when attempts > 1 ->
        serve(mode, port, attempts - 1)

      {:error, reason} ->
        flunk("the fixture never listened on #{port}: #{inspect(reason)}")
    end
  end

  # The fixture acknowledges its own successful bind, so a different server
  # on the requested port cannot satisfy readiness. No probe connections.
  defp await_listening(_port, server) do
    receive do
      {^server, {:data, {:eol, "ready"}}} -> :ok
      {^server, {:exit_status, _status}} -> {:error, :exited}
    after
      5_000 -> {:error, :startup_timeout}
    end
  end

  # Stands in for the browser: follows the authorization URL by hand and reads
  # back the query the server redirected to.
  defp browser(test \\ self()) do
    fn url, _redirect_uri ->
      send(test, {:visited, url})

      case Req.get(url, redirect: false, retry: false) do
        {:ok, %{status: 302} = response} ->
          [location | _rest] = Req.Response.get_header(response, "location")

          {:ok, location |> URI.parse() |> Map.get(:query) |> URI.decode_query()}

        {:ok, response} ->
          {:error, "the authorization endpoint answered #{response.status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp auth(context, opts \\ []) do
    Auth.new(
      Keyword.merge(
        [
          store: context.store,
          redirect_uri: "http://127.0.0.1:#{context.port}/callback",
          redirect: browser(),
          client_name: "lemieux (test)"
        ],
        opts
      )
    )
  end

  defp start(context, mode, opts \\ []) do
    serve(mode, context.port)

    start_supervised!(
      {Client,
       server: "fixture",
       transport:
         {HTTP,
          %{
            url: "http://127.0.0.1:#{context.port}/mcp",
            auth: Keyword.get(opts, :auth, auth(context))
          }},
       timeout: :timer.seconds(10)},
      id: {:oauth_client, context.port}
    )
  end

  defp http_config(context),
    do: %{"name" => "fixture", "type" => "http", "url" => "http://127.0.0.1:#{context.port}/mcp"}

  describe "a server that requires authorization" do
    test "is reached: the flow runs and its tools are listed", context do
      client = start(context, "oauth")

      assert {:ok, tools} = Client.list_tools(client)
      assert "echo" in Enum.map(tools, & &1.name)

      assert_received {:visited, url}
      assert url =~ "/authorize?"
    end

    test "and its tools can be called with the token that was obtained", context do
      client = start(context, "oauth")

      assert {:ok, _tools} = Client.list_tools(client)

      assert {:ok, %Result{model_text: "echo: hi"}} =
               Client.call_tool(client, "echo", %{"text" => "hi"})
    end

    test "is authorized once, not once per request", context do
      client = start(context, "oauth")

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, _output} = Client.call_tool(client, "echo", %{"text" => "hi"})
      assert {:ok, _output} = Client.call_tool(client, "echo", %{"text" => "again"})

      assert_received {:visited, _url}
      refute_received {:visited, _other}
    end

    test "answers a challenge that names no resource metadata, via the well-known URI",
         context do
      client = start(context, "oauth_bare")

      assert {:ok, _tools} = Client.list_tools(client)
    end

    test "is reached with a Client ID Metadata Document when that is all it offers", context do
      auth = auth(context, client_id_metadata_url: "https://lemieux.example/client.json")
      client = start(context, "oauth_cimd", auth: auth)

      assert {:ok, _tools} = Client.list_tools(client)

      assert_received {:visited, url}
      assert URI.decode(url) =~ "client_id=https://lemieux.example/client.json"
    end
  end

  describe "the authorization request" do
    test "carries PKCE, the resource, and the scope the challenge asked for", context do
      client = start(context, "oauth")

      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:visited, url}

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert params["code_challenge_method"] == "S256"
      assert params["resource"] == "http://127.0.0.1:#{context.port}/mcp"
      # The server's challenge said `scope="read"`, and the challenge is
      # authoritative for the operation.
      assert params["scope"] == "read"
      assert params["redirect_uri"] == "http://127.0.0.1:#{context.port}/callback"
    end
  end

  describe "what is kept" do
    test "the token is written to the store, keyed by issuer and resource", context do
      client = start(context, "oauth")
      assert {:ok, _tools} = Client.list_tools(client)

      issuer = "http://127.0.0.1:#{context.port}"

      assert {:ok, token} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")
      assert token["access_token"] =~ "at-"
      assert token["refresh_token"] =~ "rt-"
      assert token["requested_scopes"] == ["read"]
    end

    test "the dynamic registration is kept, so a second client does not register again",
         context do
      client = start(context, "oauth")
      assert {:ok, _tools} = Client.list_tools(client)

      issuer = "http://127.0.0.1:#{context.port}"

      assert {:ok, %{"client_id" => client_id}} = Store.fetch_client(context.store, issuer)
      assert client_id =~ "client-"
    end

    test "a token already in the store is used without a browser", context do
      client = start(context, "oauth")
      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:visited, _url}

      # A second client over the same store: same server, same credentials, and
      # nothing for a person to do.
      second =
        start_supervised!(
          {Client,
           server: "second",
           transport:
             {HTTP,
              %{
                url: "http://127.0.0.1:#{context.port}/mcp",
                auth: auth(context, redirect: fn _url, _uri -> flunk("authorized twice") end)
              }},
           timeout: :timer.seconds(10)},
          id: {:oauth_second, context.port}
        )

      assert {:ok, _tools} = Client.list_tools(second)
    end
  end

  describe "an expired token" do
    test "is refreshed mid-session, and the call succeeds", context do
      client = start(context, "oauth_short")
      issuer = "http://127.0.0.1:#{context.port}"

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, first} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")

      # Keep the client's cached token, but make the server reject it. The
      # next call must recover from the 401 rather than proactively refresh.
      assert {:ok, %{status: 200, body: %{"expired" => expired}}} =
               Req.post(issuer <> "/_fixture/expire",
                 json: %{"access_token" => first["access_token"]},
                 retry: false
               )

      assert expired == first["access_token"]

      assert {:ok, %Result{model_text: "echo: hi"}} =
               Client.call_tool(client, "echo", %{"text" => "hi"})

      assert {:ok, second} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")
      refute second["access_token"] == first["access_token"]

      # One visit, at the start. Refreshing must not need a person.
      assert_received {:visited, _url}
      refute_received {:visited, _other}
    end

    test "found in the store at startup is refreshed rather than re-authorized", context do
      client = start(context, "oauth_short")
      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:visited, _url}

      # A second client starting cold against a store whose token is already
      # spent. It has a refresh token, so nobody should be sent to a browser.
      second =
        start_supervised!(
          {Client,
           server: "second",
           transport:
             {HTTP,
              %{
                url: "http://127.0.0.1:#{context.port}/mcp",
                auth: auth(context, redirect: fn _url, _uri -> flunk("authorized again") end)
              }},
           timeout: :timer.seconds(10)},
          id: {:oauth_second, context.port}
        )

      assert {:ok, _tools} = Client.list_tools(second)
    end

    test "whose refresh is refused is forgotten, so it is not retried forever", context do
      client = start(context, "oauth_short")
      issuer = "http://127.0.0.1:#{context.port}"

      assert {:ok, _tools} = Client.list_tools(client)

      # A refresh token the authorization server has never heard of: the
      # fixture answers `invalid_grant`, which is what a revoked one looks like.
      {:ok, token} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")

      :ok =
        Store.put_token(context.store, issuer, issuer <> "/mcp", %{
          token
          | "refresh_token" => "rt-gone"
        })

      third =
        start_supervised!(
          {Client,
           server: "third",
           transport:
             {HTTP,
              %{
                url: "http://127.0.0.1:#{context.port}/mcp",
                auth: auth(context, redirect: nil)
              }},
           timeout: :timer.seconds(10)},
          id: {:oauth_third, context.port}
        )

      assert {:error, reason} = Client.list_tools(third)
      assert reason =~ "cannot open a browser"

      # And the dead token is gone rather than waiting to be retried on the
      # next run, and the one after that.
      assert Store.fetch_token(context.store, issuer, issuer <> "/mcp") == :error
    end
  end

  describe "a scope the first authorization did not ask for" do
    test "is a step up, and the second request asks for the union of both", context do
      client = start(context, "oauth")

      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:visited, first}

      assert {:ok, %Result{model_text: "you may write"}} =
               Client.call_tool(client, "privileged", %{})

      assert_received {:visited, second}

      assert scope(first) == ["read"]
      # Not just "write": asking for only the challenged scope would give up
      # the read access the session already had.
      assert Enum.sort(scope(second)) == ["read", "write"]
    end
  end

  describe "without a way to open a browser" do
    test "an unauthorized server is an error saying where to authorize instead", context do
      client = start(context, "oauth", auth: auth(context, redirect: nil))

      assert {:error, reason} = Client.list_tools(client)
      assert reason =~ "cannot open a browser"
      assert reason =~ "credentials.json"
    end
  end

  describe "while nobody is at a browser yet" do
    setup context do
      runtime = :"lemieux_mcp_auth_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      Map.put(context, :runtime, runtime)
    end

    # A session connecting its servers at startup must not hold on a browser
    # round trip nobody has started; the host offers it when asked.
    test "a server needing consent is reported as needs_auth, and no browser opens", context do
      serve("oauth", context.port)
      test = self()

      watched = fn _url, _redirect_uri ->
        send(test, :browser_opened)
        {:error, "no"}
      end

      {result, _log} =
        with_log(fn ->
          MCP.connect_server(http_config(context),
            supervisor: context.runtime,
            auth: auth(context, redirect: watched),
            interactive_auth: false
          )
        end)

      assert {:error, %{name: "fixture", reason: {:needs_auth, info}}} = result
      assert info.server == "fixture"
      assert info.url == "http://127.0.0.1:#{context.port}/mcp"
      assert info.resource =~ "/mcp"
      refute_received :browser_opened
    end

    test "a token already stored is still used", context do
      serve("oauth", context.port)
      auth = auth(context)

      {{:ok, _first}, _log} =
        with_log(fn ->
          MCP.connect_server(http_config(context), supervisor: context.runtime, auth: auth)
        end)

      {result, _log} =
        with_log(fn ->
          MCP.connect_server(http_config(context),
            supervisor: context.runtime,
            auth: auth(context, redirect: nil),
            interactive_auth: false
          )
        end)

      assert {:ok, %{tools: [_ | _]}} = result
    end
  end

  describe "with no authorization configured at all" do
    test "the refusal names what the server asked for and both ways to answer it", context do
      client = start(context, "oauth", auth: nil)

      assert {:error, reason} = Client.list_tools(client)
      assert reason =~ "HTTP 401"
      assert reason =~ "Lemieux.MCP.Auth"
      assert reason =~ "Bearer ${MY_TOKEN}"
    end
  end

  describe "a token minted for one server" do
    test "is never sent to another, even sharing a credential store", context do
      client = start(context, "oauth")
      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:visited, _first}

      # A second MCP server, on its own port, so its own issuer and its own
      # resource. Sharing the store must not share the token.
      #
      # Asked for, not guessed. This used to take the first port plus one,
      # which is very often the port some other case has just been given —
      # loopback ephemeral ports are handed out in near-sequence — and then no
      # number of retries helps, because that neighbour holds it for the rest
      # of its test.
      other = free_port()
      serve("oauth", other)

      elsewhere =
        start_supervised!(
          {Client,
           server: "elsewhere",
           transport:
             {HTTP,
              %{
                url: "http://127.0.0.1:#{other}/mcp",
                auth:
                  Auth.new(
                    store: context.store,
                    redirect_uri: "http://127.0.0.1:#{other}/callback",
                    redirect: browser()
                  )
              }},
           timeout: :timer.seconds(10)},
          id: {:oauth_elsewhere, other}
        )

      assert {:ok, _tools} = Client.list_tools(elsewhere)

      # It authorized separately rather than reaching for the token it already
      # had — which is what resource binding is for.
      assert_received {:visited, second}
      assert second =~ ":#{other}/authorize"

      issuer = "http://127.0.0.1:#{context.port}"
      other_issuer = "http://127.0.0.1:#{other}"

      assert {:ok, one} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")
      assert {:ok, two} = Store.fetch_token(context.store, other_issuer, other_issuer <> "/mcp")

      refute one["access_token"] == two["access_token"]
    end
  end

  describe "a token" do
    test "never reaches the model, in a request or a transcript or an error", context do
      runtime = :"lemieux_auth_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})

      serve("oauth", context.port)
      store = JSONL.new(context.tmp_dir)

      provider =
        Scripted.new([
          [
            {:tool_call, %{id: "m1", name: "fixture__echo", arguments: %{"text" => "hi"}}},
            {:done, :tool_calls}
          ],
          [{:done, :stop}]
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: provider,
          store: store,
          model: "test:model",
          subscriber: self(),
          tools: [],
          mcp_auth: auth(context),
          mcp_servers: [
            %{
              "name" => "fixture",
              "transport" => "http",
              "url" => "http://127.0.0.1:#{context.port}/mcp"
            }
          ]
        )

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _id, {:finished, :stop}}, 10_000

      issuer = "http://127.0.0.1:#{context.port}"
      assert {:ok, token} = Store.fetch_token(context.store, issuer, issuer <> "/mcp")
      secret = token["access_token"]

      # Everything the model was shown, and everything written down about the
      # session. A credential in either is a credential in a log file, a
      # replayed transcript, or the next request to a model vendor.
      assert {:ok, entries} = Lemieux.Store.read(store, Session.id(session))
      assert Enum.any?(entries, &(&1.type == :tool_result)), "the tool never ran"

      refute inspect(entries) =~ secret
      refute inspect(Scripted.requests(provider)) =~ secret
    end
  end

  defp scope(url) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.get("scope", "")
    |> String.split(" ", trim: true)
  end
end
