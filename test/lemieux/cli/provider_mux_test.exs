defmodule Lemieux.CLI.ProviderMuxTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ProviderMux
  alias Lemieux.Ixway
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias LemieuxTest.HTTPFixture

  @moduletag :tmp_dir

  test "a session offers both configured routes and only their own models", %{tmp_dir: dir} do
    runtime = :"lemieux_mux_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    provider =
      ProviderMux.new(
        ixway_provider(),
        ReqLLM.new(api_keys: %{"openai" => "test-key", "anthropic" => "anthropic-key"})
      )

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: provider,
        model: "ixway:team/coding",
        tools: [],
        subscriber: self()
      )

    assert "ixway" in Session.available_providers(session)
    assert "openai" in Session.available_providers(session)
    assert "anthropic" in Session.available_providers(session)
    assert Session.available_models(session, "ixway") == ["ixway:team/coding"]

    assert Session.model_metadata(session) == %{
             "ixway:team/coding" => %{kind: nil, route: "Automatic"}
           }

    openai_models = Session.available_models(session, "openai")
    assert "openai:gpt-4o-mini" in openai_models
    assert Enum.all?(openai_models, &String.starts_with?(&1, "openai:"))

    assert Enum.all?(
             Session.available_models(session, "anthropic"),
             &String.starts_with?(&1, "anthropic:")
           )

    assert {:ok, selected} = Session.set_provider(session, "openai")
    assert String.starts_with?(selected, "openai:")
    assert {:ok, "ixway:team/coding"} = Session.set_provider(session, "ixway")
    assert {:error, {:provider_unavailable, "google"}} = Session.set_provider(session, "google")
  end

  test "Ixway selections stay on Ixway and cannot fall back to a direct key" do
    provider = ProviderMux.new(ixway_provider(), ReqLLM.new(api_keys: %{"openai" => "test-key"}))

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Provider.validate_model(provider, "ixway:missing", [])

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Provider.run(provider, Request.new("ixway:missing"), fn _event -> :ok end)

    assert :ok = Provider.validate_model(provider, "openai:gpt-4o-mini", [])
    refute inspect(provider) =~ "test-key"
    refute inspect(provider) =~ "gateway-key"
  end

  test "an Ixway startup failure is not replaced with a direct model" do
    ixway = Ixway.provider(endpoint: "https://gateway.example")
    provider = ProviderMux.new(ixway, ReqLLM.new(api_keys: %{"openai" => "test-key"}))

    assert {:error, %Ixway.Error{reason: :api_key_required}} =
             ProviderMux.prepare(provider, "ixway:@default")

    assert {:ok, ^provider, "openai:gpt-4o-mini"} =
             ProviderMux.prepare(provider, "openai:gpt-4o-mini")
  end

  test "a selected direct model sends its own key to its own endpoint" do
    parent = self()

    {endpoint, listener, server} =
      HTTPFixture.server(fn headers, body, _socket ->
        send(parent, {:direct_request, headers["authorization"], JSON.decode!(body)["model"]})

        %{
          status: 200,
          headers: [{"content-type", "text/event-stream"}],
          body:
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    direct = ReqLLM.new(api_keys: %{"openai" => "direct-key"}, base_url: endpoint <> "/v1")
    provider = ProviderMux.new(ixway_provider(), direct)

    assert :ok = Provider.run(provider, Request.new("openai:gpt-4o-mini"), fn _ -> :ok end)
    assert_receive {:direct_request, "Bearer direct-key", "gpt-4o-mini"}
  end

  defp ixway_provider do
    connection =
      Ixway.new(endpoint: "https://gateway.example", api_key: "gateway-key")

    Ixway.provider(%{
      connection
      | models: [
          %{
            "id" => "team/coding",
            "ixway_ingress_dialects" => ["openai_chat"],
            "ixway_default_for" => ["openai_chat"],
            "max_input_tokens" => 32_000
          }
        ],
        client_policy: %{"default_profile" => %{"id" => "team/coding", "status" => "available"}}
    })
  end
end
