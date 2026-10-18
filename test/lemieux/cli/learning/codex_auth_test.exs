defmodule Lemieux.CLI.Learning.CodexAuthTest do
  use ExUnit.Case, async: false
  alias Lemieux.CLI.Learning.CodexAuth
  @moduletag :tmp_dir
  @now ~U[2026-10-18 12:00:00Z]

  setup do
    previous = Application.fetch_env(:req_llm, :oauth_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, :oauth_file, value)
        :error -> Application.delete_env(:req_llm, :oauth_file)
      end
    end)
  end

  defp source(dir, remaining) do
    token =
      "header." <>
        Base.url_encode64(JSON.encode!(%{"exp" => DateTime.to_unix(@now) + remaining}),
          padding: false
        ) <> ".signature"

    bytes =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => token,
          "refresh_token" => "never-loan-this",
          "account_id" => "test-account"
        }
      })

    path = Path.join(dir, "auth.json")
    File.write!(path, bytes)
    {path, bytes}
  end

  test "borrows access only into a private file, preserves source and removes the loan", %{
    tmp_dir: dir
  } do
    {source, original} = source(dir, 86_400)
    path = Path.join(dir, "loan/oauth.json")

    assert {:ok, ^path, %{expires_at: _}} =
             CodexAuth.prepare(source: source, path: path, now: @now, min_validity_hours: 2)

    entry = JSON.decode!(File.read!(path))["openai-codex"]
    assert Enum.sort(Map.keys(entry)) == ~w(access accountId expires type)
    refute File.read!(path) =~ "never-loan-this"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert File.read!(source) == original
    assert :ok = CodexAuth.cleanup(path)
    refute File.exists?(path)
    assert File.read!(source) == original
  end

  test "missing, malformed or short-lived access refuses before a loan is written", %{
    tmp_dir: dir
  } do
    {source, _} = source(dir, 60)
    path = Path.join(dir, "loan/oauth.json")

    assert {:error, {:codex_token_expires_too_soon, _, 2}} =
             CodexAuth.prepare(source: source, path: path, now: @now, min_validity_hours: 2)

    refute File.exists?(path)
    File.write!(source, "{}")
    assert {:error, _} = CodexAuth.prepare(source: source, path: path, now: @now)
    File.rm!(source)
    assert {:error, _} = CodexAuth.prepare(source: source, path: path, now: @now)
  end
end
