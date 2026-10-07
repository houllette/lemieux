defmodule LemieuxComputerUse.SystemOneTest do
  use ExUnit.Case, async: true

  alias LemieuxComputerUse.{Decision, SystemOne}
  alias LemieuxComputerUse.SystemOne.Transport
  alias Pristine.Core.{Context, Request, Response}
  alias SystemOneSDK.Providers.{Endpoint, TypeSafe}
  alias SystemOneSDK.Test

  defmodule FailingProvider do
    @behaviour SystemOneSDK.Provider

    @impl true
    def id, do: :failing_test_provider

    @impl true
    def new_client(_opts), do: :test_client

    @impl true
    def default_model(:test_client), do: "local-model"

    @impl true
    def system_one(:test_client, _state, _questions, opts) do
      send(self(), {:provider_options, opts})
      {:error, "provider secret"}
    end

    @impl true
    def list_models(:test_client, _opts), do: {:error, :unused}

    @impl true
    def capabilities(:test_client), do: %{}
  end

  @request %{
    "state" => %{"page" => %{"title" => "Search"}},
    "questions" => %{
      "operation" => %{
        "type" => "choice",
        "criteria" => %{"CLICK" => "Click", "DONE" => "Done"}
      },
      "click_target" => %{
        "type" => "choice",
        "criteria" => %{"1" => ~s({"label":"Search"}), "2" => ~s({"label":"Help"})}
      }
    }
  }

  @local %{
    name: "local",
    type: :endpoint,
    base_url: "http://127.0.0.1:11434",
    api_key: nil,
    api_key_header: nil,
    headers: %{},
    model: "clef-flash"
  }

  @typesafe %{
    name: "typesafe",
    type: :typesafe,
    base_url: "https://api.typesafe.ai",
    api_key: "test-secret",
    api_key_header: nil,
    headers: %{},
    model: nil
  }

  test "SDK sends portable questions: string descriptions and no one-option choice" do
    page = %{
      "url" => "https://example.com/",
      "title" => "Search",
      "text" => "Find a hotel",
      "actions" => [
        %{"id" => "1", "operation" => "CLICK", "label" => "Search", "role" => "button"},
        %{"id" => "2", "operation" => "CLICK", "label" => "Help", "role" => "a"},
        %{"id" => "3", "operation" => "TYPE_TEXT", "label" => "City", "role" => "input"}
      ]
    }

    request = Decision.request(page, "Search for Lisbon", [], [])

    client =
      Test.client(
        api_key: "test-secret",
        base_url: "https://api.typesafe.ai",
        model: "jev-1.13.0"
      )

    # The stub refuses a request whose questions differ from the stubbed
    # ones, so a type_text_target question would fail here.
    Test.stub(
      client,
      %{
        "operation" => {:choice, "TYPE_TEXT", confidence: 0.9},
        "click_target" => {:choice, "1", confidence: 0.95}
      },
      usage: %{input_tokens: 17, output_tokens: 2}
    )

    assert {:ok, response} = SystemOne.evaluate(request, client: client)
    assert response["model"] == "jev-1.13.0"
    assert response["usage"] == %{"input_tokens" => 17, "output_tokens" => 2}
    assert Map.keys(response) |> Enum.sort() == ~w(answers model usage)

    assert [sent] = Test.requests(client)
    assert sent.method == :post
    assert URI.parse(sent.url).path == "/v1/systemone"

    assert Enum.any?(sent.headers, fn {name, value} ->
             String.downcase(to_string(name)) == "authorization" and value == "Bearer test-secret"
           end)

    body = sent.body |> IO.iodata_to_binary() |> Jason.decode!()
    assert body == Map.put(request, "model", "jev-1.13.0")
    assert Map.keys(body["questions"]) |> Enum.sort() == ["click_target", "operation"]

    assert body["questions"]["click_target"]["criteria"] == %{
             "1" => ~s({"label":"Search","role":"button"}),
             "2" => ~s({"label":"Help","role":"a"})
           }

    assert {:ok, %{"id" => "3", "operation" => "TYPE_TEXT"},
            %{"operation_confidence" => 0.9, "target_confidence" => nil}} =
             Decision.decode(request, response, page)

    Test.verify!(client)
    Test.close(client)
  end

  test "a keyless local provider becomes an Endpoint client that sends no credential" do
    assert {:ok, client} = SystemOne.client(provider: @local)
    assert client.provider == Endpoint
    assert client.base_url == "http://127.0.0.1:11434"
    assert client.api_key == nil
    assert client.default_model == "clef-flash"
    assert client.transport == Transport

    {base_url, server} = serve_once(200, [{"content-type", "application/json"}], answer("nimble"))
    provider = %{@local | base_url: base_url, model: "nimble"}

    assert {:ok, %{"model" => "nimble", "answers" => %{"click_target" => %{"choice" => "1"}}}} =
             SystemOne.evaluate(@request, provider: provider)

    sent = Task.await(server)
    assert String.contains?(sent, "POST /v1/systemone")
    refute String.contains?(String.downcase(sent), "authorization")
  end

  test "a TypeSafe provider becomes a TypeSafe client with Jev as its default model" do
    assert {:ok, client} = SystemOne.client(provider: @typesafe)
    assert client.provider == TypeSafe
    assert client.base_url == "https://api.typesafe.ai"
    assert client.default_model == "jev-1.13.0"

    assert {:ok, %{default_model: "jev-1.14.0"}} =
             SystemOne.client(provider: %{@typesafe | model: "jev-1.14.0"})
  end

  test "a key with its own header travels in that header, never as a bearer token" do
    {base_url, server} = serve_once(200, [{"content-type", "application/json"}], answer("vendor"))

    provider = %{
      @local
      | name: "vendor",
        base_url: base_url <> "/account",
        api_key: "test-secret",
        api_key_header: "x-api-key",
        headers: %{"x-tenant" => "t1"},
        model: "vendor"
    }

    assert {:ok, client} = SystemOne.client(provider: provider)
    assert client.api_key == nil

    assert {:ok, _response} = SystemOne.evaluate(@request, provider: provider)
    sent = String.downcase(Task.await(server))
    assert String.contains?(sent, "post /account/v1/systemone")
    assert String.contains?(sent, "x-api-key: test-secret")
    assert String.contains?(sent, "x-tenant: t1")
    refute String.contains?(sent, "authorization")
  end

  test "a provider no request could be built for is refused before anything is sent" do
    unusable = [
      %{@typesafe | api_key: nil},
      %{@typesafe | api_key: "  "},
      %{@local | name: "ixway", base_url: "https://gateway.example"},
      %{@local | model: nil},
      %{@local | base_url: "ftp://127.0.0.1"},
      %{@local | base_url: "http://user:secret@127.0.0.1:11434"},
      %{@local | base_url: "http://127.0.0.1:11434?key=secret"}
    ]

    for provider <- unusable do
      assert {:error, "System One provider is unusable"} = SystemOne.client(provider: provider)

      assert {:error, "System One provider is unusable"} =
               SystemOne.evaluate(@request, provider: provider)
    end
  end

  test "with no provider and no client there is no classifier, and no fallback" do
    assert {:error, "no System One provider is configured"} = SystemOne.evaluate(@request, [])
    assert {:error, "no System One provider is configured"} = SystemOne.client(timeout_ms: 1_000)
    assert {:error, "System One client is invalid"} = SystemOne.evaluate(@request, client: %{})
  end

  test "the options of the TypeSafe-only classifier are refused, naming provider:" do
    for removed <- [[api_key: "test-secret"], [model: "jev-1.13.0"]] do
      assert_raise ArgumentError, ~r/provider:/, fn -> SystemOne.evaluate(@request, removed) end
      assert {:error, message} = SystemOne.validate_options(removed)
      assert message =~ "provider:"
      refute message =~ "test-secret"
    end

    assert {:error, message} = SystemOne.validate_options(providers: @local)
    assert message =~ ":providers"
    assert {:error, _} = SystemOne.validate_options(provider: %{base_url: "http://x"})
    assert {:error, _} = SystemOne.validate_options(timeout_ms: 0)
    assert :ok = SystemOne.validate_options(provider: @local, timeout_ms: 5_000)
  end

  test "an answer from a model that was not asked is not the run's judgement" do
    client = Test.client(model: "jev-1.13.0")

    Test.stub(
      client,
      %{
        "operation" => {:choice, "CLICK", confidence: 0.9},
        "click_target" => {:choice, "1", 0.9}
      },
      model: "another-model"
    )

    assert {:error, "System One returned an invalid response"} =
             SystemOne.evaluate(@request, client: client)

    Test.close(client)
  end

  test "SDK errors are sanitized and a configured retry policy cannot add attempts" do
    client =
      Test.client(
        api_key: "test-secret",
        retry: [max_retries: 2, backoff_initial: 0, backoff_jitter: 0]
      )

    Test.stub_http_error(client, 401, body: %{"error" => "test-secret"})

    assert {:error, "System One returned HTTP 401"} =
             SystemOne.evaluate(@request, client: client)

    assert Test.stats(client).total == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "invalid provider responses do not enter browser evidence" do
    client = Test.client()
    Test.stub_response(client, %{"model" => "jev-1.13.0", "answers" => %{}, "usage" => "secret"})

    assert {:error, "System One returned an invalid response"} =
             SystemOne.evaluate(@request, client: client)

    Test.verify!(client)
    Test.close(client)
  end

  test "a selected SDK provider is the sole path and its error text is not retained" do
    client = SystemOneSDK.new_client(provider: FailingProvider)

    assert {:error, "System One transport failed"} = SystemOne.evaluate(@request, client: client)
    assert_receive {:provider_options, opts}
    assert opts[:model] == "local-model"
    assert opts[:retry] == false
  end

  test "a host-supplied SDK client executes through the guarded transport" do
    {base_url, server} =
      serve_once(200, [{"content-type", "application/json"}], answer("jev-1.13.0"))

    client =
      SystemOneSDK.new_client(
        api_key: "test-secret",
        base_url: base_url,
        model: "jev-1.13.0",
        retry: false,
        transport: Transport
      )

    assert {:ok, %{"answers" => %{"click_target" => %{"choice" => "1"}}}} =
             SystemOne.evaluate(@request, client: client)

    sent = Task.await(server)
    assert String.contains?(sent, "POST /v1/systemone")
    assert String.contains?(String.downcase(sent), "authorization: bearer test-secret")
  end

  test "guarded transport returns redirects and retry-after responses without another request" do
    for {status, headers} <- [
          {302, [{"location", "http://127.0.0.1:1/redirected"}]},
          {503, [{"retry-after", "1"}]}
        ] do
      {base_url, server} = serve_once(status, headers, "")

      request = %Request{
        method: :post,
        url: base_url <> "/v1/systemone",
        headers: %{"authorization" => "Bearer test-secret"},
        body: "{}",
        metadata: %{timeout: 1_000}
      }

      assert {:ok, %Response{status: ^status}} = Transport.send(request, %Context{})
      assert String.contains?(Task.await(server), "POST /v1/systemone")
    end
  end

  defp answer(model) do
    Jason.encode!(%{
      model: model,
      usage: %{input_tokens: 17, output_tokens: 2},
      answers: %{
        operation: %{
          type: "choice",
          choice: "CLICK",
          confidence: 0.9,
          probabilities: %{CLICK: 1.0, DONE: 0.0}
        },
        click_target: %{
          type: "choice",
          choice: "1",
          confidence: 0.95,
          probabilities: %{"1" => 1.0, "2" => 0.0}
        }
      }
    })
  end

  defp serve_once(status, headers, body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, sent} = :gen_tcp.recv(socket, 0, 5_000)

        response =
          [
            "HTTP/1.1 ",
            Integer.to_string(status),
            " Test\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n",
            Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
            "\r\n",
            body
          ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        sent
      end)

    {"http://127.0.0.1:#{port}", server}
  end
end
