defmodule Lemieux.MCP.Auth.ChallengeTest do
  @moduledoc """
  Reading a `WWW-Authenticate` header.

  The examples here are the literal headers real MCP servers answered with on
  2026-08-14, not invented ones — including Atlassian's, which carries no
  `resource_metadata` at all and is the reason the well-known fallback exists.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Auth.Challenge

  describe "parsing" do
    test "reads the parameters out of a bearer challenge" do
      header =
        ~s(Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", error="invalid_token", error_description="Missing or invalid access token")

      assert %Challenge{} = challenge = Challenge.parse(header)

      assert challenge.resource_metadata ==
               "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"

      assert challenge.error == "invalid_token"
      assert challenge.scopes == []
    end

    test "reads the scopes a server says it needs, which are authoritative" do
      header =
        ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/x", scope="files:read files:write")

      assert %Challenge{scopes: ["files:read", "files:write"]} = Challenge.parse(header)
    end

    test "copes with a challenge naming no resource metadata" do
      header =
        ~s(Bearer realm="OAuth", error="invalid_token", error_description="Missing or invalid access token")

      assert %Challenge{resource_metadata: nil, error: "invalid_token"} = Challenge.parse(header)
    end

    test "copes with no challenge at all" do
      assert %Challenge{resource_metadata: nil, scopes: []} = Challenge.parse(nil)
    end

    test "does not mistake a comma inside a quoted value for a parameter boundary" do
      header =
        ~s(Bearer error_description="Missing, or invalid, access token", error="invalid_token")

      assert %Challenge{error: "invalid_token"} = challenge = Challenge.parse(header)
      assert challenge.error_description == "Missing, or invalid, access token"
    end

    test "accepts an unquoted parameter value, which the grammar allows" do
      assert %Challenge{error: "insufficient_scope"} =
               Challenge.parse(~s(Bearer error=insufficient_scope, scope="a b"))
    end

    test "is case insensitive about the scheme and the parameter names" do
      assert %Challenge{error: "invalid_token"} =
               Challenge.parse(~s(bearer ERROR="invalid_token"))
    end
  end

  describe "what the challenge means" do
    test "an insufficient_scope challenge is a step-up, not a fresh authorization" do
      header = ~s(Bearer error="insufficient_scope", scope="files:write")

      assert Challenge.parse(header) |> Challenge.step_up?()
    end

    test "an ordinary invalid_token challenge is not" do
      refute Challenge.parse(~s(Bearer error="invalid_token")) |> Challenge.step_up?()
    end
  end
end
