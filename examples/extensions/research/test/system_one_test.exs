defmodule ResearchExtension.SystemOneTest do
  use ExUnit.Case, async: false

  alias ResearchExtension.{Discovery, SystemOne}
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
    assert is_function(Discovery.resolve(provider: "auto")[:classify], 1)
    assert Discovery.resolve(false) == nil
    refute inspect(Discovery.resolve(nil)) =~ "environment-secret"
  end

  test "saved personal credentials enable discovery and environment takes precedence", %{
    tmp_dir: directory
  } do
    config(directory, %{"typesafe" => %{"api_key" => "saved-secret"}})
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

  test "a keyless local provider is posted to its own URL with its model and no credential" do
    classify = capture(local())
    assert {:ok, result} = classify.(question())
    assert result == response("clef-flash")

    assert_receive {:request, opts}
    assert opts[:url] == "http://127.0.0.1:11434/v1/systemone"
    refute Keyword.has_key?(opts, :auth)
    assert opts[:headers] == %{}
    assert opts[:json] == Map.put(question(), "model", "clef-flash")
    assert opts[:retry] == false
    assert opts[:redirect] == false
    assert opts[:receive_timeout] == 15_000

    classify = capture(%{local() | base_url: "https://decisions.example/team/7"})
    assert {:ok, _} = classify.(question())
    assert_receive {:request, opts}
    assert opts[:url] == "https://decisions.example/team/7/v1/systemone"
  end

  test "TypeSafe takes the key as a bearer token and pins its model" do
    classify = capture(typesafe("typesafe-secret"), "jev-1.13.0")
    assert {:ok, _} = classify.(question())
    assert_receive {:request, opts}
    assert opts[:url] == "https://api.typesafe.ai/v1/systemone"
    assert opts[:auth] == {:bearer, "typesafe-secret"}
    assert opts[:json]["model"] == "jev-1.13.0"
    refute inspect(classify) =~ "typesafe-secret"
  end

  test "api_key_header carries the key in that header and sends no bearer token" do
    provider = %{
      local()
      | api_key: "header-secret",
        api_key_header: "x-api-key",
        headers: %{"x-team" => "research"}
    }

    classify = capture(provider)
    assert {:ok, _} = classify.(question())
    assert_receive {:request, opts}
    assert opts[:headers] == %{"x-api-key" => "header-secret", "x-team" => "research"}
    refute Keyword.has_key?(opts, :auth)
  end

  test "a provider name resolves from the lmx config file", %{tmp_dir: directory} do
    config(directory, %{
      "local" => %{
        "base_url" => "http://127.0.0.1:11434",
        "model" => "nimble",
        "api_key" => "saved-local-secret",
        "api_key_header" => "x-api-key"
      }
    })

    owner = self()

    request = fn opts ->
      send(owner, {:request, opts})
      {:ok, %Req.Response{status: 200, body: response("nimble")}}
    end

    resolved = Discovery.resolve(provider: "local", request: request)
    refute Keyword.has_key?(resolved, :provider)
    refute inspect(resolved) =~ "saved-local-secret"
    assert {:ok, _} = resolved[:classify].(question())
    assert_receive {:request, opts}
    assert opts[:url] == "http://127.0.0.1:11434/v1/systemone"
    assert opts[:json]["model"] == "nimble"
    assert opts[:headers] == %{"x-api-key" => "saved-local-secret"}
  end

  test "a named provider that cannot be used is an error, never discovery off", %{
    tmp_dir: directory
  } do
    config(directory, %{"local" => %{"base_url" => "http://127.0.0.1:11434"}})

    for {name, reason} <- [
          {"missing", "does not declare"},
          {"local", "has no model"},
          {"typesafe", "has no key"}
        ] do
      assert {:error, message} = SystemOne.classifier(provider: name)
      assert message =~ "System One discovery is unavailable"
      assert message =~ reason
      assert_raise ArgumentError, message, fn -> Discovery.resolve(provider: name) end
    end

    # Unnamed, the same file is simply no provider: discovery stays off.
    assert SystemOne.classifier([]) == :unavailable
  end

  test "an unusable provider map is an error that does not echo its credentials" do
    for provider <- [
          %{local() | model: nil},
          %{local() | base_url: "http://user:url-secret@127.0.0.1:11434"},
          %{local() | base_url: "ftp://127.0.0.1"},
          typesafe(nil),
          %{type: :other, base_url: "http://127.0.0.1"},
          42
        ] do
      assert {:error, message} = SystemOne.classifier(provider: provider)
      refute message =~ "url-secret"
    end
  end

  test "api_key: is refused with a message naming provider:" do
    System.put_env("JEV_API_KEY", "environment-secret")
    assert {:error, message} = SystemOne.classifier(api_key: "explicit-secret")
    assert message =~ "provider:"
    refute message =~ "explicit-secret"

    error = assert_raise ArgumentError, fn -> Discovery.resolve(api_key: "explicit-secret") end
    refute Exception.message(error) =~ "explicit-secret"
  end

  test "transport, HTTP, model and malformed errors discard provider details" do
    for {result, message} <- [
          {{:error, %RuntimeError{message: "explicit-secret"}}, "System One transport failed"},
          {{:ok, %Req.Response{status: 401, body: "explicit-secret"}},
           "System One returned HTTP 401"},
          {{:ok, %Req.Response{status: 302, body: "explicit-secret"}},
           "System One returned HTTP 302"},
          {{:ok, %Req.Response{status: 200, body: %{}}},
           "System One returned an invalid response"},
          {{:ok, %Req.Response{status: 200, body: response("explicit-secret")}},
           "System One answered with a model other than the one requested"}
        ] do
      assert {:ok, classify} =
               SystemOne.classifier(
                 provider: typesafe("explicit-secret"),
                 request: fn _ -> result end
               )

      assert {:error, ^message} = classify.(question())
    end

    assert {:ok, classify} = SystemOne.classifier(provider: local(), request: &flunk/1)
    assert {:error, "System One request is invalid"} = classify.(%{"state" => "only"})
  end

  defp capture(provider, model \\ "clef-flash") do
    owner = self()

    request = fn opts ->
      send(owner, {:request, opts})
      {:ok, %Req.Response{status: 200, body: response(model)}}
    end

    {:ok, classify} = SystemOne.classifier(provider: provider, request: request)
    classify
  end

  defp config(directory, providers) do
    path = Path.join(directory, "config.json")
    File.write!(path, JSON.encode!(%{"systemone_providers" => providers}))
    File.chmod!(path, 0o600)
    System.put_env("LMX_CONFIG", path)
  end

  defp local,
    do: %{
      name: "local",
      type: :endpoint,
      base_url: "http://127.0.0.1:11434/",
      api_key: nil,
      api_key_header: nil,
      headers: %{},
      model: "clef-flash"
    }

  defp typesafe(key),
    do: %{
      name: "typesafe",
      type: :typesafe,
      base_url: "https://api.typesafe.ai",
      api_key: key,
      api_key_header: nil,
      headers: %{},
      model: nil
    }

  defp question,
    do: %{"state" => "test", "questions" => %{"next" => %{"type" => "choice"}}}

  defp response(model \\ "jev-1.13.0"),
    do: %{"answers" => %{}, "model" => model, "usage" => %{"input_tokens" => 1}}
end
