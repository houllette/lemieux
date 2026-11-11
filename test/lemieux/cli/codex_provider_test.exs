defmodule Lemieux.CLI.CodexProviderTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{CodexProvider, Config, Models, Options}
  alias Lemieux.{Provider, Request}
  @moduletag :tmp_dir

  defmodule Capture do
    def run(pid, request, _emit) do
      send(pid, {:request, request})
      :ok
    end
  end

  defp source(dir, seconds) do
    token =
      "header." <>
        Base.url_encode64(JSON.encode!(%{"exp" => System.system_time(:second) + seconds}),
          padding: false
        ) <> ".signature"

    path = Path.join(dir, "auth.json")

    body =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => token,
          "account_id" => "test",
          "refresh_token" => "do-not-copy"
        }
      })

    File.write!(path, body)
    {path, body, token}
  end

  test "offers usable Codex sign-in even after Ollama was automatically chosen", %{tmp_dir: dir} do
    {path, original, _token} = source(dir, 3600)
    options = %Options{model: "ollama:nimble", config: %Config{personal: true}}
    options = put_in(options.host.model_source, :ollama)

    panel =
      Models.first_run(options,
        codex_source: path,
        env: %{},
        ollama: [get: fn _, _ -> {:error, :offline} end]
      )

    assert panel.intro =~ "active local Codex sign-in"
    assert [%{id: "openai_codex", remember?: true} | _] = panel.providers
    assert File.read!(path) == original
    assert Models.first_run(%{options | config: nil}, codex_source: path, env: %{}) == nil
  end

  test "an expired previously selected sign-in explains renewal", %{tmp_dir: dir} do
    {path, _, _} = source(dir, -10)
    options = %Options{model: "openai_codex:gpt-6-sol", config: %Config{personal: true}}

    panel =
      Models.first_run(options,
        codex_source: path,
        env: %{},
        ollama: [get: fn _, _ -> {:error, :offline} end]
      )

    assert panel.intro =~ "codex login"
    refute Enum.any?(panel.providers, &(&1.id == "openai_codex"))
  end

  test "explicit request auth takes precedence over local Codex borrowing", %{tmp_dir: dir} do
    provider = CodexProvider.wrap({Capture, self()}, source: Path.join(dir, "missing"))

    request =
      Request.new("openai_codex:gpt-6-sol",
        params: [provider_options: [access_token: "explicit-test-token"]]
      )

    assert :ok = Provider.run(provider, request, fn _ -> :ok end)
    assert_receive {:request, ^request}
  end

  test "reads current access token per request, leaves refresh with Codex and explains expiry", %{
    tmp_dir: dir
  } do
    {path, original, token} = source(dir, 3600)
    provider = CodexProvider.wrap({Capture, self()}, source: path)
    request = Request.new("openai_codex:gpt-6-sol")
    assert :ok = Provider.run(provider, request, fn _ -> :ok end)
    assert_receive {:request, effective}
    assert effective.params[:provider_options][:access_token] == token
    refute inspect(effective.params) =~ "do-not-copy"
    assert request.params == []
    assert File.read!(path) == original
    source(dir, -10)
    assert {:error, message} = Provider.run(provider, request, fn _ -> :ok end)
    assert message =~ "codex login"
    refute_receive {:request, _}
    assert :ok = Provider.run(provider, Request.new("openai:gpt-6-sol"), fn _ -> :ok end)
    assert_receive {:request, %{params: []}}
  end
end
