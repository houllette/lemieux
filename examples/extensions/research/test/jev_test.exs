defmodule ResearchExtension.JevTest do
  use ExUnit.Case, async: false

  alias ResearchExtension.{Discovery, Jev}
  @moduletag :tmp_dir

  setup do
    previous = Map.take(System.get_env(), ["JEV_API_KEY", "LMX_CONFIG"])
    System.delete_env("JEV_API_KEY")
    System.put_env("LMX_CONFIG", "none")

    on_exit(fn ->
      for name <- ["JEV_API_KEY", "LMX_CONFIG"] do
        case previous[name] do
          nil -> System.delete_env(name)
          value -> System.put_env(name, value)
        end
      end
    end)
  end

  test "a key automatically enables discovery and false always opts out" do
    assert Discovery.resolve(nil) == nil
    System.put_env("JEV_API_KEY", "environment-secret")
    assert is_function(Discovery.resolve(nil)[:classify], 1)
    assert Discovery.resolve(false) == nil
    refute inspect(Discovery.resolve(nil)) =~ "environment-secret"
    refute inspect(Discovery.resolve(api_key: "explicit-secret")) =~ "explicit-secret"
  end

  test "saved personal credentials enable discovery and environment takes precedence", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "systemone_compaction_providers" => %{"typesafe" => %{"api_key" => "saved-secret"}}
      })
    )

    File.chmod!(path, 0o600)
    System.put_env("LMX_CONFIG", path)
    owner = self()

    request = fn opts ->
      send(owner, {:auth, opts[:auth]})
      {:ok, %Req.Response{status: 200, body: response()}}
    end

    classify = Discovery.resolve(request: request)[:classify]
    assert {:ok, _} = classify.(question())
    assert_receive {:auth, {:bearer, "saved-secret"}}

    System.put_env("JEV_API_KEY", "environment-secret")
    classify = Discovery.resolve(request: request)[:classify]
    assert {:ok, _} = classify.(question())
    assert_receive {:auth, {:bearer, "environment-secret"}}
  end

  test "explicit callbacks bypass automatic credential resolution" do
    System.put_env("LMX_CONFIG", "/missing/config.json")
    callback = fn _ -> {:ok, response()} end
    assert Discovery.resolve(classify: callback)[:classify] == callback
    assert Discovery.resolve(false) == nil
    assert_raise ArgumentError, fn -> Discovery.resolve(classify: nil) end
    assert_raise ArgumentError, fn -> Discovery.resolve(nil) end
  end

  test "native classification pins the endpoint and model and never retries or redirects" do
    owner = self()

    request = fn opts ->
      send(owner, {:request, opts})
      {:ok, %Req.Response{status: 200, body: Map.put(response(), "private", "hidden")}}
    end

    assert {:ok, classify} = Jev.classifier(api_key: "explicit-secret", request: request)
    assert {:ok, result} = classify.(question())
    assert result == response()
    refute inspect(classify) =~ "explicit-secret"
    assert_receive {:request, opts}
    assert opts[:url] == "https://api.typesafe.ai/v1/systemone"
    assert opts[:auth] == {:bearer, "explicit-secret"}
    assert opts[:json] == Map.put(question(), "model", "jev-1.13.0")
    assert opts[:retry] == false
    assert opts[:redirect] == false
    assert opts[:receive_timeout] == 15_000
  end

  test "transport, HTTP and malformed errors discard provider details" do
    for {result, message} <- [
          {{:error, %RuntimeError{message: "explicit-secret"}}, "Jev transport failed"},
          {{:ok, %Req.Response{status: 401, body: "explicit-secret"}}, "Jev returned HTTP 401"},
          {{:ok, %Req.Response{status: 302, body: "explicit-secret"}}, "Jev returned HTTP 302"},
          {{:ok, %Req.Response{status: 200, body: %{}}}, "Jev returned an invalid response"}
        ] do
      assert {:ok, classify} =
               Jev.classifier(api_key: "explicit-secret", request: fn _ -> result end)

      assert {:error, ^message} = classify.(question())
    end
  end

  defp question,
    do: %{"state" => "test", "questions" => %{"next" => %{"type" => "choice"}}}

  defp response,
    do: %{"answers" => %{}, "model" => "jev-1.13.0", "usage" => %{"input_tokens" => 1}}
end
