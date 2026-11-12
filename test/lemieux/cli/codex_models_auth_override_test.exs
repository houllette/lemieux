defmodule Lemieux.CLI.CodexModelsAuthOverrideTest do
  use ExUnit.Case, async: false
  alias Lemieux.CLI.{CodexModels, CodexProvider, Config, Options}
  @moduletag :tmp_dir
  @env ~w(REQ_LLM_OAUTH_FILE REQ_LLM_AUTH_FILE)
  @keys [:oauth_file, :auth_file]

  setup %{tmp_dir: dir} do
    env = Map.new(@env, &{&1, System.get_env(&1)})
    config = Map.new(@keys, &{&1, Application.fetch_env(:req_llm, &1)})
    Enum.each(@env, &System.delete_env/1)
    Enum.each(@keys, &Application.delete_env(:req_llm, &1))

    on_exit(fn ->
      Enum.each(env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Enum.each(config, fn
        {key, {:ok, value}} -> Application.put_env(:req_llm, key, value)
        {key, :error} -> Application.delete_env(:req_llm, key)
      end)
    end)

    path = Path.join(dir, "oauth.json")

    body =
      JSON.encode!(%{
        "openai-codex" => %{
          "access" => "explicit-access",
          "accountId" => "explicit-account",
          "expires" => System.system_time(:millisecond) + 3_600_000,
          "refresh" => "never-refresh"
        }
      })

    File.write!(path, body)

    %{
      path: path,
      body: body,
      options: %Options{model: "openai_codex:gpt-6.1-sol", config: %Config{personal: true}},
      source: Path.join(dir, "no-native-file")
    }
  end

  test "both ReqLLM environment override spellings select the inference credential", ctx do
    for key <- @env do
      System.put_env(key, ctx.path)
      refute CodexProvider.local_auth?([])
      assert {:ok, connection} = CodexModels.connection(ctx.options, source: ctx.source)
      assert connection.account_id == "explicit-account"
      assert connection.token == "explicit-access"
      assert File.read!(ctx.path) == ctx.body
      System.delete_env(key)
    end
  end

  test "application override wins over environment; request auth wins over both", ctx do
    System.put_env("REQ_LLM_OAUTH_FILE", Path.join(Path.dirname(ctx.path), "missing"))
    Application.put_env(:req_llm, :auth_file, ctx.path)
    assert {:ok, from_file} = CodexModels.connection(ctx.options, source: ctx.source)
    assert from_file.token == "explicit-access"

    assert {:ok, request} =
             CodexModels.connection(ctx.options,
               source: ctx.source,
               params: [access_token: "request-access", chatgpt_account_id: "request-account"]
             )

    assert request.token == "request-access"
    refute request.scope == from_file.scope

    assert {:ok, nested} =
             CodexModels.connection(ctx.options,
               source: ctx.source,
               params: [
                 provider_options: [
                   openai_codex: [
                     access_token: "namespaced",
                     chatgpt_account_id: "namespaced-account"
                   ]
                 ]
               ]
             )

    assert nested.token == "namespaced"

    refute CodexProvider.local_auth?(
             provider_options: [openai_codex: [access_token: "namespaced"]]
           )
  end

  test "changing the explicit source invalidates the scope even with the same account and token",
       ctx do
    copy = ctx.path <> ".copy"
    File.write!(copy, ctx.body)

    assert {:ok, first} =
             CodexModels.connection(ctx.options,
               source: ctx.source,
               params: [oauth_file: ctx.path]
             )

    assert {:ok, second} =
             CodexModels.connection(ctx.options, source: ctx.source, params: [oauth_file: copy])

    refute first.scope == second.scope
    assert first.token == second.token
  end
end
