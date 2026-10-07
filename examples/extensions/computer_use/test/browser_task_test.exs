defmodule LemieuxComputerUse.BrowserTaskTest do
  # How `mix lmx.browser --systemone-provider NAME` finds its provider: the
  # lmx config file LMX_CONFIG names, resolved as lmx resolves it.
  #
  # Not async: resolution reads LMX_CONFIG, JEV_API_KEY, IXWAY_API_KEY and
  # LMX_IXWAY_URL.
  use ExUnit.Case, async: false

  alias LemieuxComputerUse.SystemOne
  alias Mix.Tasks.Lmx.Browser

  @moduletag :tmp_dir
  @variables ~w(LMX_CONFIG JEV_API_KEY IXWAY_API_KEY LMX_IXWAY_URL)

  setup %{tmp_dir: dir} do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "systemone_providers" => %{
          "local" => %{"base_url" => "http://127.0.0.1:11434", "model" => "clef-flash"},
          "ixway" => %{"model" => "gateway-model"}
        }
      })
    )

    File.chmod!(path, 0o600)
    System.put_env("LMX_CONFIG", path)
    :ok
  end

  test "a declared provider is resolved from the config file LMX_CONFIG names" do
    assert {:ok,
            %{
              name: "local",
              type: :endpoint,
              base_url: "http://127.0.0.1:11434",
              api_key: nil,
              model: "clef-flash"
            } = provider} = Browser.system_one_provider("local")

    assert {:ok, %SystemOneSDK.Client{provider: SystemOneSDK.Providers.Endpoint}} =
             SystemOne.client(provider: provider)
  end

  test "a name the file does not declare is refused with the flag that named it" do
    assert {:error, reason} = Browser.system_one_provider("elsewhere")

    assert reason ==
             "The browser needs a System One provider, but --systemone-provider names a " <>
               "provider systemone_providers does not declare."

    System.put_env("LMX_CONFIG", "none")
    assert {:error, ^reason} = Browser.system_one_provider("local")
  end

  test "the automatic choice is TypeSafe with its key, and nothing without one" do
    assert {:error, reason} = Browser.system_one_provider(nil)
    assert reason =~ "but no provider is complete"
    assert reason =~ "--systemone-provider"

    System.put_env("JEV_API_KEY", "test-secret")

    assert {:ok, %{name: "typesafe", type: :typesafe, api_key: "test-secret"}} =
             Browser.system_one_provider("auto")
  end

  test "a resolved provider the classifier could not reach is refused before the browser" do
    System.put_env("IXWAY_API_KEY", "test-secret")
    System.put_env("LMX_IXWAY_URL", "ftp://gateway.example")

    assert {:error, reason} = Browser.system_one_provider("ixway")
    assert reason =~ "The ixway System One provider cannot be used"
    refute reason =~ "test-secret"
  end

  test "the task stops on the sentence before it starts a browser" do
    assert_raise Mix.Error, ~r/does not declare/, fn ->
      Browser.run(["--demo", "--systemone-provider", "elsewhere"])
    end
  end

  test "the classifier itself reads no key from the environment" do
    System.put_env("JEV_API_KEY", "test-secret")

    request = %{"state" => %{}, "questions" => %{}}
    assert {:error, "no System One provider is configured"} = SystemOne.evaluate(request, [])
  end
end
