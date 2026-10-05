defmodule Lemieux.MCP.Auth.FlowTest do
  @moduledoc """
  The authorization code flow, as data.

  Nothing here opens a browser or binds a port — the library computes a URL for
  somebody else to visit and reads back what came out of the redirect. Four of
  these tests are about refusing things, and they are the point of the module:
  a flow that accepts a mismatched `state` or an `iss` from the wrong issuer is
  the attack this whole exchange exists to prevent.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Auth.Flow

  @metadata %{
    "issuer" => "https://mcp.example.com",
    "authorization_endpoint" => "https://mcp.example.com/authorize",
    "token_endpoint" => "https://mcp.example.com/token",
    "code_challenge_methods_supported" => ["S256"]
  }

  @client %{"client_id" => "https://lemieux.example/client.json"}

  defp start(opts \\ []) do
    Flow.start(
      @metadata,
      @client,
      Keyword.merge(
        [
          resource: "https://mcp.example.com/mcp",
          redirect_uri: "http://127.0.0.1:8642/callback",
          scopes: ["read"]
        ],
        opts
      )
    )
  end

  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "the authorization URL" do
    test "carries PKCE, state, and the resource being asked for" do
      {url, pending} = start()
      params = query(url)

      assert String.starts_with?(url, "https://mcp.example.com/authorize?")
      assert params["response_type"] == "code"
      assert params["client_id"] == "https://lemieux.example/client.json"
      assert params["redirect_uri"] == "http://127.0.0.1:8642/callback"
      assert params["code_challenge_method"] == "S256"
      assert params["resource"] == "https://mcp.example.com/mcp"
      assert params["scope"] == "read"
      assert params["state"] == pending.state
    end

    test "sends the challenge and never the verifier" do
      {url, pending} = start()
      params = query(url)

      expected = Base.url_encode64(:crypto.hash(:sha256, pending.verifier), padding: false)

      assert params["code_challenge"] == expected
      refute url =~ pending.verifier
    end

    test "is different every time, so two flows cannot be confused for each other" do
      {_url, one} = start()
      {_url, two} = start()

      refute one.state == two.state
      refute one.verifier == two.verifier
    end

    test "records the issuer to check the response against" do
      {_url, pending} = start()

      assert pending.issuer == "https://mcp.example.com"
    end

    test "omits scope entirely when there is none to ask for" do
      {url, _pending} = start(scopes: [])

      refute Map.has_key?(query(url), "scope")
    end
  end

  describe "reading the redirect" do
    test "returns the code when the state matches" do
      {_url, pending} = start()

      assert {:ok, "the-code"} =
               Flow.finish(pending, %{"code" => "the-code", "state" => pending.state})
    end

    test "a mismatched state is refused" do
      {_url, pending} = start()

      assert {:error, reason} =
               Flow.finish(pending, %{"code" => "the-code", "state" => "somebody-else's"})

      assert reason =~ "state"
    end

    test "a missing state is refused too, since one was sent" do
      {_url, pending} = start()

      assert {:error, _reason} = Flow.finish(pending, %{"code" => "the-code"})
    end

    test "a response whose iss is not the issuer we recorded is refused" do
      {_url, pending} = start()

      params = %{"code" => "c", "state" => pending.state, "iss" => "https://attacker.example"}

      assert {:error, reason} = Flow.finish(pending, params)
      assert reason =~ "issuer"
    end

    test "an iss that matches is accepted" do
      {_url, pending} = start()

      params = %{"code" => "c", "state" => pending.state, "iss" => "https://mcp.example.com"}

      assert {:ok, "c"} = Flow.finish(pending, params)
    end

    test "an absent iss is accepted when the server does not claim to send one" do
      {_url, pending} = start()

      assert {:ok, "c"} = Flow.finish(pending, %{"code" => "c", "state" => pending.state})
    end

    test "an absent iss is refused when the server said it would send one" do
      metadata = Map.put(@metadata, "authorization_response_iss_parameter_supported", true)
      {_url, pending} = Flow.start(metadata, @client, resource: "r", redirect_uri: "u")

      assert {:error, reason} = Flow.finish(pending, %{"code" => "c", "state" => pending.state})
      assert reason =~ "iss"
    end

    test "an error from the authorization server is reported as itself" do
      {_url, pending} = start()

      params = %{
        "error" => "access_denied",
        "error_description" => "the user said no",
        "state" => pending.state
      }

      assert {:error, reason} = Flow.finish(pending, params)
      assert reason =~ "access_denied"
      assert reason =~ "the user said no"
    end

    test "an error whose iss is wrong has nothing of it repeated back" do
      {_url, pending} = start()

      params = %{
        "error" => "access_denied",
        "error_description" => "click here to fix: https://phishing.example",
        "state" => pending.state,
        "iss" => "https://attacker.example"
      }

      assert {:error, reason} = Flow.finish(pending, params)
      refute reason =~ "phishing.example"
      refute reason =~ "access_denied"
    end
  end

  describe "exchanging the code" do
    test "sends the verifier, the resource and the redirect it was authorized against" do
      {_url, pending} = start()

      post = fn url, form ->
        send(self(), {:exchanged, url, form})

        {:ok, %{"access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600}}
      end

      assert {:ok, token} = Flow.exchange(@metadata, @client, pending, "the-code", post: post)

      assert_received {:exchanged, "https://mcp.example.com/token", form}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "the-code"
      assert form["code_verifier"] == pending.verifier
      assert form["redirect_uri"] == "http://127.0.0.1:8642/callback"
      assert form["resource"] == "https://mcp.example.com/mcp"
      assert form["client_id"] == "https://lemieux.example/client.json"

      assert token["access_token"] == "at"
      assert token["refresh_token"] == "rt"
    end

    test "turns expires_in into a moment, since that is what outlives the request" do
      {_url, pending} = start()
      post = fn _url, _form -> {:ok, %{"access_token" => "at", "expires_in" => 3600}} end

      assert {:ok, token} = Flow.exchange(@metadata, @client, pending, "c", post: post)

      assert_in_delta token["expires_at"], System.system_time(:second) + 3600, 5
    end

    test "a token response with no access token is an error rather than a token" do
      {_url, pending} = start()
      post = fn _url, _form -> {:ok, %{"token_type" => "Bearer"}} end

      assert {:error, reason} = Flow.exchange(@metadata, @client, pending, "c", post: post)
      assert reason =~ "access_token"
    end

    test "a client secret is sent when there is one, and omitted when there is not" do
      {_url, pending} = start()
      post = fn _url, form -> {:ok, %{"access_token" => form["client_secret"] || "none"}} end

      assert {:ok, %{"access_token" => "none"}} =
               Flow.exchange(@metadata, @client, pending, "c", post: post)

      confidential = Map.put(@client, "client_secret", "shh")

      assert {:ok, %{"access_token" => "shh"}} =
               Flow.exchange(@metadata, confidential, pending, "c", post: post)
    end
  end

  describe "refreshing" do
    test "spends the refresh token and keeps the resource binding" do
      post = fn url, form ->
        send(self(), {:refreshed, url, form})

        {:ok, %{"access_token" => "at-2", "expires_in" => 60}}
      end

      token = %{"access_token" => "at-1", "refresh_token" => "rt-1"}

      assert {:ok, refreshed} =
               Flow.refresh(@metadata, @client, token, "https://mcp.example.com/mcp", post: post)

      assert_received {:refreshed, "https://mcp.example.com/token", form}
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "rt-1"
      assert form["resource"] == "https://mcp.example.com/mcp"

      assert refreshed["access_token"] == "at-2"
    end

    test "keeps the old refresh token when the server rotates nothing back" do
      post = fn _url, _form -> {:ok, %{"access_token" => "at-2"}} end
      token = %{"access_token" => "at-1", "refresh_token" => "rt-1"}

      assert {:ok, %{"refresh_token" => "rt-1"}} =
               Flow.refresh(@metadata, @client, token, "r", post: post)
    end

    test "takes the rotated refresh token when the server sends one" do
      post = fn _url, _form -> {:ok, %{"access_token" => "at-2", "refresh_token" => "rt-2"}} end
      token = %{"access_token" => "at-1", "refresh_token" => "rt-1"}

      assert {:ok, %{"refresh_token" => "rt-2"}} =
               Flow.refresh(@metadata, @client, token, "r", post: post)
    end

    test "a token with nothing to refresh with says so rather than asking" do
      post = fn _url, _form -> flunk("asked the token endpoint with no refresh token") end

      assert {:error, reason} =
               Flow.refresh(@metadata, @client, %{"access_token" => "at"}, "r", post: post)

      assert reason =~ "refresh"
    end
  end

  describe "expiry" do
    test "a token with no expiry is taken at face value" do
      refute Flow.expired?(%{"access_token" => "at"})
    end

    test "a token whose moment has passed is expired" do
      assert Flow.expired?(%{"expires_at" => System.system_time(:second) - 1})
    end

    test "a token about to expire is treated as expired, because the request takes time" do
      assert Flow.expired?(%{"expires_at" => System.system_time(:second) + 5})
      refute Flow.expired?(%{"expires_at" => System.system_time(:second) + 600})
    end
  end
end
