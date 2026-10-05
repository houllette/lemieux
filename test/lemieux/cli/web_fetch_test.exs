defmodule Lemieux.CLI.WebFetchTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Elixir, as: ElixirProfile
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tools.WebFetch

  @moduletag :tmp_dir

  setup do
    saved = %{
      "LMX_WEB_FETCH" => System.get_env("LMX_WEB_FETCH"),
      "LMX_WEB_SEARCH" => System.get_env("LMX_WEB_SEARCH"),
      "BRAVE_SEARCH_API_KEY" => System.get_env("BRAVE_SEARCH_API_KEY")
    }

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(Map.keys(saved), &System.delete_env/1)
    :ok
  end

  test "fetch is absent unless explicitly selected" do
    assert {:ok, options} = Options.parse([])
    assert options.web_fetch == false
    assert {:ok, tools} = Runtime.standard_tools(options, [])
    refute "web_fetch" in Enum.map(tools, &Tool.name/1)
  end

  test "the flag, the environment and the config file each select it, in that order",
       %{tmp_dir: tmp_dir} do
    assert {:ok, %{web_fetch: true}} = Options.parse(["--web-fetch"])

    System.put_env("LMX_WEB_FETCH", "1")
    assert {:ok, %{web_fetch: true}} = Options.parse([])
    assert {:ok, %{web_fetch: false}} = Options.parse(["--no-web-fetch"])

    System.put_env("LMX_WEB_FETCH", "0")
    assert {:ok, %{web_fetch: false}} = Options.parse([])

    System.put_env("LMX_WEB_FETCH", "maybe")
    assert {:error, message} = Options.parse([])
    assert message =~ "LMX_WEB_FETCH must be 1 or 0"
    System.delete_env("LMX_WEB_FETCH")

    path = Path.join(tmp_dir, "config.json")
    File.write!(path, ~s({"version":1,"web_fetch":true}))
    File.chmod!(path, 0o600)
    assert {:ok, %{web_fetch: true}} = Options.parse(["--config", path])
    assert {:ok, %{web_fetch: false}} = Options.parse(["--config", path, "--no-web-fetch"])

    File.write!(path, ~s({"version":1,"web_fetch":"yes"}))
    assert {:error, message} = Options.parse(["--config", path])
    assert message =~ "web_fetch"
  end

  test "a selected fetch joins the standard profile after search, but not Elixir-only mode" do
    System.put_env("BRAVE_SEARCH_API_KEY", "super-secret")
    assert {:ok, options} = Options.parse(["--web-search", "brave", "--web-fetch"])

    assert {:ok, standard} = Runtime.standard_tools(options, interactive?: true)

    assert Enum.map(standard, &Tool.name/1) ==
             ~w(read grep glob write edit bash ask_user web_search web_fetch research_check todo)

    assert %WebFetch{unsafe_allow_loopback_for_tests: false} =
             Enum.find(standard, &(Tool.name(&1) == "web_fetch"))

    focused = ElixirProfile.apply(Harness.new(tools: standard), [])
    assert Enum.map(focused.tools, &Tool.name/1) == ~w(elixir ask_user)

    assert {:ok, only_fetch} = Options.parse(["--web-fetch"])
    assert {:ok, tools} = Runtime.standard_tools(only_fetch, [])

    assert Enum.map(tools, &Tool.name/1) ==
             ~w(read grep glob write edit bash web_search web_fetch research_check todo)

    assert {:ok, no_fetch} = Options.parse(["--no-web-fetch"])
    assert {:ok, tools} = Runtime.standard_tools(no_fetch, [])
    assert Enum.map(tools, &Tool.name/1) == ~w(read grep glob write edit bash web_search todo)
  end

  test "resume rebinds fetch only when the current host selects it again", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    assert {:ok, original_options} = Options.parse(["--web-fetch"])
    original_supervisor = unique_supervisor("original")

    assert {:ok, original} =
             Runtime.start_session(original_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: original_supervisor
             )

    id = Session.id(original)
    assert "web_fetch" in Session.snapshot(original).tools
    Supervisor.stop(original_supervisor)

    assert {:ok, plain_options} = Options.parse(["--resume", id])
    plain_supervisor = unique_supervisor("plain")

    assert {:ok, plain} =
             Runtime.start_session(plain_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: plain_supervisor
             )

    refute "web_fetch" in Session.snapshot(plain).tools
    Supervisor.stop(plain_supervisor)

    assert {:ok, rebound_options} = Options.parse(["--resume", id, "--web-fetch"])
    rebound_supervisor = unique_supervisor("rebound")

    assert {:ok, rebound} =
             Runtime.start_session(rebound_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: rebound_supervisor
             )

    assert "web_fetch" in Session.snapshot(rebound).tools
    Supervisor.stop(rebound_supervisor)
  end

  defp unique_supervisor(label),
    do: :"lemieux_cli_web_fetch_#{label}_#{System.unique_integer([:positive])}"
end
