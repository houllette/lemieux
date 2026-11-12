defmodule Lemieux.CLI.CodexModelsTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{CodexModels, Config, Options}
  @moduletag :tmp_dir

  defp options, do: %Options{model: "openai_codex:gpt-6.1-sol", config: %Config{personal: true}}

  defp token(account, expires) do
    payload = %{
      "exp" => expires,
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => account}
    }

    "header." <> Base.url_encode64(JSON.encode!(payload), padding: false) <> ".signature"
  end

  defp local(dir, account \\ "native") do
    access = token(account, System.system_time(:second) + 3600)
    path = Path.join(dir, "auth.json")

    body =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => access,
          "account_id" => account,
          "refresh_token" => "never-copy"
        }
      })

    File.write!(path, body)
    {path, access, body}
  end

  test "fetches visible account models, including unknown slugs, without inference", %{
    tmp_dir: dir
  } do
    {path, access, body} = local(dir)
    assert {:ok, connection} = CodexModels.connection(options(), source: path)
    refute inspect(connection) =~ access

    get = fn url, request ->
      assert url == "https://chatgpt.com/backend-api/codex/models"
      assert request[:params] == [client_version: "0.167.2"]

      assert request[:headers] == [
               {"authorization", "Bearer " <> access},
               {"chatgpt-account-id", "native"}
             ]

      assert request[:retry] == false
      assert request[:redirect] == false

      {:ok,
       %{
         status: 200,
         body: %{
           "models" => [
             %{"slug" => "gpt-6.1-sol", "visibility" => "list"},
             %{"slug" => "future-account-model", "visibility" => "list"},
             %{"slug" => "hidden", "visibility" => "hide"},
             %{"slug" => "not-listed"},
             %{"slug" => "bad\nslug", "visibility" => "list"},
             %{"slug" => "future-account-model", "visibility" => "list"}
           ]
         }
       }}
    end

    assert {:ok, ["openai_codex:gpt-6.1-sol", "openai_codex:future-account-model"]} =
             CodexModels.fetch(connection, get: get)

    assert {:ok, %{provider: :openai_codex, id: "future-account-model"}} =
             ReqLLM.model("openai_codex:future-account-model")

    assert File.read!(path) == body
  end

  test "explicit access auth and account take precedence and change the cache scope", %{
    tmp_dir: dir
  } do
    {path, _, _} = local(dir)

    params = [
      provider_options: [
        access_token: token("explicit", System.system_time(:second) + 3600),
        chatgpt_account_id: "chosen"
      ]
    ]

    assert {:ok, native} = CodexModels.connection(options(), source: path)
    assert {:ok, explicit} = CodexModels.connection(options(), source: path, params: params)
    assert explicit.account_id == "chosen"
    refute explicit.scope == native.scope

    assert {:ok, other} =
             CodexModels.connection(options(),
               source: path,
               params: Keyword.put(params, :chatgpt_account_id, "other")
             )

    refute other.scope == explicit.scope
  end

  test "reads ReqLLM OAuth overrides without writing or refreshing them", %{tmp_dir: dir} do
    {path, _, _} = local(dir)
    oauth = Path.join(dir, "req-oauth.json")

    body =
      JSON.encode!(%{
        "openai-codex" => %{
          "access" => token("override", System.system_time(:second) + 3600),
          "accountId" => "override",
          "refresh" => "never-use",
          "expires" => System.system_time(:millisecond) + 3_600_000
        }
      })

    File.write!(oauth, body)

    assert {:ok, connection} =
             CodexModels.connection(options(), source: path, params: [oauth_file: oauth])

    assert connection.account_id == "override"
    assert File.read!(oauth) == body

    File.write!(
      oauth,
      JSON.encode!(%{
        "openai-codex" => %{"access" => "expired", "expires" => 1, "refresh" => "never-use"}
      })
    )

    assert {:error, :expired} =
             CodexModels.connection(options(), source: path, params: [oauth_file: oauth])

    assert File.read!(path) =~ "never-copy"

    assert {:error, :credentials} =
             CodexModels.connection(options(),
               source: path,
               params: [oauth_file: Path.join(dir, "missing")]
             )
  end

  test "hermetic runs skip native borrowing and custom inference endpoints are not guessed", %{
    tmp_dir: dir
  } do
    {path, _, _} = local(dir)
    assert :unconfigured = CodexModels.connection(%{options() | config: nil}, source: path)

    assert {:error, :unsupported_route} =
             CodexModels.connection(%{options() | base_url: "https://private.example/v1"},
               source: path
             )
  end

  test "failures carry safe categories without raw provider or credential payloads", %{
    tmp_dir: dir
  } do
    {path, _, _} = local(dir)
    {:ok, connection} = CodexModels.connection(options(), source: path)

    for {response, reason} <- [
          {{:ok, %{status: 401, body: "secret"}}, :unauthorized},
          {{:ok, %{status: 503, body: "secret"}}, :unavailable},
          {{:error, :secret}, :unavailable},
          {{:ok, %{status: 200, body: %{"models" => "wrong"}}}, :invalid_catalog}
        ] do
      assert {:error, ^reason} = CodexModels.fetch(connection, get: fn _, _ -> response end)
      refute CodexModels.message(reason) =~ "secret"
    end
  end
end
