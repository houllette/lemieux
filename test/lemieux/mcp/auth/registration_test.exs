defmodule Lemieux.MCP.Auth.RegistrationTest do
  @moduledoc """
  Getting a client id, by whichever of the three ways this server allows.

  The spike measured eight hosted MCP servers: seven accept Dynamic Client
  Registration, three accept Client ID Metadata Documents, and GitHub accepts
  neither and wants a client id somebody registered by hand. So all three
  branches here are load-bearing — a client that implements only the mechanism
  the specification prefers reaches three of the eight.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Auth.Registration
  alias Lemieux.MCP.Auth.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{store: Store.File.new(Path.join(tmp_dir, "credentials.json"))}
  end

  defp metadata(extra \\ %{}) do
    Map.merge(
      %{
        "issuer" => "https://mcp.example.com",
        "authorization_endpoint" => "https://mcp.example.com/authorize",
        "token_endpoint" => "https://mcp.example.com/token"
      },
      extra
    )
  end

  defp opts(context, extra) do
    Keyword.merge(
      [
        store: context.store,
        client_name: "lemieux",
        redirect_uris: ["http://127.0.0.1:8642/callback"],
        post: fn _url, _body -> {:error, "no registration endpoint was expected"} end
      ],
      extra
    )
  end

  describe "priority" do
    test "a pre-registered client id is used in preference to everything", context do
      opts =
        opts(context,
          clients: %{"https://mcp.example.com" => %{"client_id" => "hand-registered"}},
          client_id_metadata_url: "https://lemieux.example/client.json"
        )

      metadata =
        metadata(%{
          "client_id_metadata_document_supported" => true,
          "registration_endpoint" => "https://mcp.example.com/register"
        })

      assert {:ok, client} = Registration.resolve(metadata, opts)
      assert client["client_id"] == "hand-registered"
    end

    test "CIMD is used when the server advertises it", context do
      opts = opts(context, client_id_metadata_url: "https://lemieux.example/client.json")

      metadata =
        metadata(%{
          "client_id_metadata_document_supported" => true,
          "registration_endpoint" => "https://mcp.example.com/register"
        })

      assert {:ok, client} = Registration.resolve(metadata, opts)
      assert client["client_id"] == "https://lemieux.example/client.json"
    end

    test "DCR is the fallback when the server does not advertise CIMD", context do
      post = fn "https://mcp.example.com/register", body ->
        send(self(), {:registered, body})

        {:ok, %{"client_id" => "dcr-1", "client_secret" => "shh"}}
      end

      opts =
        opts(context,
          client_id_metadata_url: "https://lemieux.example/client.json",
          post: post
        )

      metadata = metadata(%{"registration_endpoint" => "https://mcp.example.com/register"})

      assert {:ok, %{"client_id" => "dcr-1", "client_secret" => "shh"}} =
               Registration.resolve(metadata, opts)

      assert_received {:registered, body}
      assert body["application_type"] == "native"
      assert body["redirect_uris"] == ["http://127.0.0.1:8642/callback"]
      assert "refresh_token" in body["grant_types"]
    end

    test "DCR is also the fallback when no metadata document is configured to point at",
         context do
      post = fn _url, _body -> {:ok, %{"client_id" => "dcr-1"}} end

      opts = opts(context, client_id_metadata_url: nil, post: post)

      metadata =
        metadata(%{
          "client_id_metadata_document_supported" => true,
          "registration_endpoint" => "https://mcp.example.com/register"
        })

      assert {:ok, %{"client_id" => "dcr-1"}} = Registration.resolve(metadata, opts)
    end

    test "a server offering none of them is an error naming what to do about it", context do
      assert {:error, reason} = Registration.resolve(metadata(), opts(context, []))

      assert reason =~ "https://mcp.example.com"
      assert reason =~ "client_id"
    end
  end

  describe "a registration obtained dynamically" do
    test "is kept, so a second run does not register again", context do
      post = fn _url, _body -> {:ok, %{"client_id" => "dcr-1"}} end
      opts = opts(context, post: post)
      metadata = metadata(%{"registration_endpoint" => "https://mcp.example.com/register"})

      assert {:ok, %{"client_id" => "dcr-1"}} = Registration.resolve(metadata, opts)

      refuse = fn _url, _body -> flunk("registered a second time") end

      assert {:ok, %{"client_id" => "dcr-1"}} =
               Registration.resolve(metadata, opts(context, post: refuse))
    end

    test "is not reused at a different authorization server", context do
      post = fn _url, _body -> {:ok, %{"client_id" => "dcr-1"}} end
      opts = opts(context, post: post)

      assert {:ok, _client} =
               Registration.resolve(
                 metadata(%{"registration_endpoint" => "https://mcp.example.com/register"}),
                 opts
               )

      other =
        metadata(%{
          "issuer" => "https://other.example.com",
          "registration_endpoint" => "https://other.example.com/register"
        })

      registered = fn "https://other.example.com/register", _body ->
        {:ok, %{"client_id" => "dcr-2"}}
      end

      assert {:ok, %{"client_id" => "dcr-2"}} =
               Registration.resolve(other, opts(context, post: registered))
    end

    test "a rejection says what the server refused", context do
      post = fn _url, _body -> {:error, "invalid_redirect_uri"} end
      opts = opts(context, post: post)
      metadata = metadata(%{"registration_endpoint" => "https://mcp.example.com/register"})

      assert {:error, reason} = Registration.resolve(metadata, opts)
      assert reason =~ "invalid_redirect_uri"
    end
  end

  describe "the metadata document lemieux publishes about itself" do
    test "names itself as its own client id, which is what makes it valid" do
      document = Registration.metadata_document("https://lemieux.example/client.json", "lemieux")

      assert document["client_id"] == "https://lemieux.example/client.json"
      assert document["client_name"] == "lemieux"
    end

    test "declares the loopback redirect URIs with and without a port" do
      document =
        Registration.metadata_document("https://lemieux.example/client.json", "lemieux",
          redirect_uris: ["http://127.0.0.1:8642/callback"]
        )

      # Both forms, because servers disagree: RFC 8252 says ignore the port on
      # a loopback URI, and several do not.
      assert "http://127.0.0.1:8642/callback" in document["redirect_uris"]
      assert "http://127.0.0.1/callback" in document["redirect_uris"]
      assert "http://localhost:8642/callback" in document["redirect_uris"]
    end
  end
end
