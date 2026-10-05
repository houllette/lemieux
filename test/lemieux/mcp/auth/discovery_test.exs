defmodule Lemieux.MCP.Auth.DiscoveryTest do
  @moduledoc """
  Finding the authorization server from a refused request.

  The URLs asserted here are the ones real servers actually answer on, measured
  on 2026-08-14 and recorded in `docs/mcp.md`. Two of them are
  the reason the probe has more than one step: Atlassian names no resource
  metadata in its challenge, and GitHub's issuer has a path component, so
  appending the well-known suffix to it gets a 404 while inserting it works.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Auth.Challenge
  alias Lemieux.MCP.Auth.Discovery

  defp get(responses) do
    fn url ->
      case Map.fetch(responses, url) do
        {:ok, body} -> {:ok, body}
        :error -> {:error, "404 for #{url}"}
      end
    end
  end

  describe "where to look for protected resource metadata" do
    test "the challenge is believed when it names one" do
      challenge =
        Challenge.parse(
          ~s(Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        )

      assert Discovery.resource_metadata_urls("https://mcp.linear.app/mcp", challenge) == [
               "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"
             ]
    end

    test "a challenge that names none falls back to the well-known URIs, path first" do
      challenge = Challenge.parse(~s(Bearer realm="OAuth", error="invalid_token"))

      assert Discovery.resource_metadata_urls("https://mcp.atlassian.com/v1/sse", challenge) == [
               "https://mcp.atlassian.com/.well-known/oauth-protected-resource/v1/sse",
               "https://mcp.atlassian.com/.well-known/oauth-protected-resource"
             ]
    end

    test "a server at the root has only the root form to try" do
      assert Discovery.resource_metadata_urls("https://mcp.example.com", %Challenge{}) == [
               "https://mcp.example.com/.well-known/oauth-protected-resource"
             ]
    end
  end

  describe "where to look for authorization server metadata" do
    test "an issuer with a path component is probed by insertion first" do
      assert Discovery.authorization_server_urls("https://github.com/login/oauth") == [
               "https://github.com/.well-known/oauth-authorization-server/login/oauth",
               "https://github.com/.well-known/openid-configuration/login/oauth",
               "https://github.com/login/oauth/.well-known/openid-configuration"
             ]
    end

    test "an issuer without one has two forms" do
      assert Discovery.authorization_server_urls("https://mcp.linear.app") == [
               "https://mcp.linear.app/.well-known/oauth-authorization-server",
               "https://mcp.linear.app/.well-known/openid-configuration"
             ]
    end
  end

  describe "following the challenge" do
    test "reaches the authorization server named by the metadata" do
      challenge =
        Challenge.parse(
          ~s(Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        )

      get =
        get(%{
          "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp" => %{
            "resource" => "https://mcp.linear.app/mcp",
            "authorization_servers" => ["https://mcp.linear.app"],
            "scopes_supported" => ["read", "write"]
          }
        })

      assert {:ok, resource} =
               Discovery.resource("https://mcp.linear.app/mcp", challenge, get: get)

      assert resource.resource == "https://mcp.linear.app/mcp"
      assert resource.issuer == "https://mcp.linear.app"
      assert resource.scopes_supported == ["read", "write"]
    end

    test "tries the next well-known URI when the first is not there" do
      get =
        get(%{
          "https://mcp.atlassian.com/.well-known/oauth-protected-resource" => %{
            "resource" => "https://mcp.atlassian.com/v1/sse",
            "authorization_servers" => ["https://mcp.atlassian.com"]
          }
        })

      assert {:ok, %{issuer: "https://mcp.atlassian.com"}} =
               Discovery.resource("https://mcp.atlassian.com/v1/sse", %Challenge{}, get: get)
    end

    test "metadata naming no authorization server is an error saying so" do
      get =
        get(%{
          "https://mcp.example.com/.well-known/oauth-protected-resource" => %{
            "resource" => "https://mcp.example.com"
          }
        })

      assert {:error, reason} =
               Discovery.resource("https://mcp.example.com", %Challenge{}, get: get)

      assert reason =~ "authorization server"
    end

    # Atlassian publishes nothing at either well-known URI, so refusing here
    # would mean a conforming client that cannot reach a server people use.
    # The guess is checked afterwards, by the issuer validation below.
    test "a server publishing none of it is assumed to be its own authorization server" do
      assert {:ok, resource} =
               Discovery.resource("https://mcp.atlassian.com/v1/sse", %Challenge{}, get: get(%{}))

      assert resource.issuer == "https://mcp.atlassian.com"
      assert resource.resource == "https://mcp.atlassian.com/v1/sse"
    end

    test "something that is not a URL at all is still an error" do
      assert {:error, reason} = Discovery.resource("not-a-url", %Challenge{}, get: get(%{}))

      assert reason =~ "not-a-url"
    end
  end

  describe "the authorization server's own metadata" do
    test "is validated against the issuer it was asked for" do
      get =
        get(%{
          "https://attacker.example/.well-known/oauth-authorization-server" => %{
            "issuer" => "https://honest.example",
            "authorization_endpoint" => "https://honest.example/authorize",
            "token_endpoint" => "https://honest.example/token",
            "code_challenge_methods_supported" => ["S256"]
          }
        })

      assert {:error, reason} =
               Discovery.authorization_server("https://attacker.example", get: get)

      assert reason =~ "issuer"
    end

    test "must advertise a PKCE method, because that is the only way to know it has one" do
      get =
        get(%{
          "https://mcp.example.com/.well-known/oauth-authorization-server" => %{
            "issuer" => "https://mcp.example.com",
            "authorization_endpoint" => "https://mcp.example.com/authorize",
            "token_endpoint" => "https://mcp.example.com/token"
          }
        })

      assert {:error, reason} =
               Discovery.authorization_server("https://mcp.example.com", get: get)

      assert reason =~ "PKCE"
    end

    test "is accepted when it names an issuer, endpoints and S256" do
      get =
        get(%{
          "https://mcp.linear.app/.well-known/oauth-authorization-server" => %{
            "issuer" => "https://mcp.linear.app",
            "authorization_endpoint" => "https://mcp.linear.app/authorize",
            "token_endpoint" => "https://mcp.linear.app/token",
            "registration_endpoint" => "https://mcp.linear.app/register",
            "client_id_metadata_document_supported" => true,
            "code_challenge_methods_supported" => ["S256"]
          }
        })

      assert {:ok, metadata} = Discovery.authorization_server("https://mcp.linear.app", get: get)
      assert metadata["token_endpoint"] == "https://mcp.linear.app/token"
      assert metadata["client_id_metadata_document_supported"] == true
    end

    test "a server advertising only plain is refused, because OAuth 2.1 requires S256" do
      get =
        get(%{
          "https://mcp.example.com/.well-known/oauth-authorization-server" => %{
            "issuer" => "https://mcp.example.com",
            "authorization_endpoint" => "https://mcp.example.com/authorize",
            "token_endpoint" => "https://mcp.example.com/token",
            "code_challenge_methods_supported" => ["plain"]
          }
        })

      assert {:error, reason} =
               Discovery.authorization_server("https://mcp.example.com", get: get)

      assert reason =~ "S256"
    end
  end
end
