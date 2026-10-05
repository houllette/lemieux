defmodule LemieuxComputerUse.JevTest do
  use ExUnit.Case, async: true

  alias LemieuxComputerUse.Jev
  alias LemieuxComputerUse.Jev.Transport
  alias Pristine.Core.{Context, Request, Response}
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
        "criteria" => %{"1" => %{"label" => "Search"}}
      }
    }
  }

  test "SDK sends the native request and preserves singleton choices and narrow evidence" do
    client =
      Test.client(
        api_key: "test-secret",
        base_url: "https://api.typesafe.ai",
        model: "jev-1.13.0"
      )

    Test.stub(
      client,
      %{
        "operation" =>
          {:choice, "CLICK", probabilities: %{"CLICK" => 1.0, "DONE" => 0.0}, confidence: 0.9},
        "click_target" => {:choice, "1", probabilities: %{"1" => 1.0}, confidence: 0.95}
      },
      usage: %{input_tokens: 17, output_tokens: 2}
    )

    assert {:ok, response} = Jev.evaluate(@request, client: client)
    assert response["model"] == "jev-1.13.0"
    assert response["usage"] == %{"input_tokens" => 17, "output_tokens" => 2}
    assert response["answers"]["click_target"]["choice"] == "1"
    assert Map.keys(response) |> Enum.sort() == ~w(answers model usage)

    assert [sent] = Test.requests(client)
    assert sent.method == :post
    assert URI.parse(sent.url).path == "/v1/systemone"

    assert Enum.any?(sent.headers, fn {name, value} ->
             String.downcase(to_string(name)) == "authorization" and value == "Bearer test-secret"
           end)

    assert sent.body |> IO.iodata_to_binary() |> Jason.decode!() ==
             Map.put(@request, "model", "jev-1.13.0")

    Test.verify!(client)
    Test.close(client)
  end

  test "SDK errors are sanitized and a configured retry policy cannot add attempts" do
    client =
      Test.client(
        api_key: "test-secret",
        retry: [max_retries: 2, backoff_initial: 0, backoff_jitter: 0]
      )

    Test.stub_http_error(client, 401, body: %{"error" => "test-secret"})

    assert {:error, "Jev returned HTTP 401"} = Jev.evaluate(@request, client: client)
    assert Test.stats(client).total == 1
    Test.verify!(client)
    Test.close(client)
  end

  test "invalid provider responses do not enter browser evidence" do
    client = Test.client()
    Test.stub_response(client, %{"model" => "jev-1.13.0", "answers" => %{}, "usage" => "secret"})

    assert {:error, "Jev returned an invalid response"} = Jev.evaluate(@request, client: client)
    Test.verify!(client)
    Test.close(client)
  end

  test "requires credentials for the default hosted provider" do
    assert {:error, "JEV_API_KEY is required"} = Jev.evaluate(@request, api_key: "")
  end

  test "a selected SDK provider is the sole path and its error text is not retained" do
    client = SystemOneSDK.new_client(provider: FailingProvider)

    assert {:error, "Jev transport failed"} = Jev.evaluate(@request, client: client)
    assert_receive {:provider_options, opts}
    assert opts[:model] == "local-model"
    assert opts[:retry] == false
  end

  test "a host-supplied SDK client executes through the guarded transport" do
    body =
      Jason.encode!(%{
        model: "jev-1.13.0",
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
            probabilities: %{"1" => 1.0}
          }
        }
      })

    {base_url, server} = serve_once(200, [{"content-type", "application/json"}], body)

    client =
      SystemOneSDK.new_client(
        api_key: "test-secret",
        base_url: base_url,
        model: "jev-1.13.0",
        retry: false,
        transport: Transport
      )

    assert {:ok, %{"answers" => %{"click_target" => %{"choice" => "1"}}}} =
             Jev.evaluate(@request, client: client)

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
