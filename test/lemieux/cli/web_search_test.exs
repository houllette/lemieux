defmodule Lemieux.CLI.WebSearchTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Elixir, as: ElixirProfile
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @moduletag :tmp_dir

  setup do
    saved = %{
      "LMX_WEB_SEARCH" => System.get_env("LMX_WEB_SEARCH"),
      "BRAVE_SEARCH_API_KEY" => System.get_env("BRAVE_SEARCH_API_KEY")
    }

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.delete_env("LMX_WEB_SEARCH")
    System.delete_env("BRAVE_SEARCH_API_KEY")

    :ok
  end

  test "search is absent unless explicitly selected" do
    assert {:ok, options} = Options.parse([])
    assert options.web_search == nil
    assert {:ok, tools} = Runtime.standard_tools(options, [])
    refute "web_search" in Enum.map(tools, &Tool.name/1)
  end

  test "the environment explicitly selects Brave and a flag overrides it" do
    System.put_env("LMX_WEB_SEARCH", "brave")
    assert {:ok, %{web_search: "brave"}} = Options.parse([])

    assert {:error, reason} = Options.parse(["--web-search", "unknown"])
    assert reason =~ "supported backend"
  end

  test "selecting Brave requires its credential without exposing it in an error" do
    assert {:ok, options} = Options.parse(["--web-search", "brave"])

    assert {:error, message} = Runtime.standard_tools(options, [])
    assert message =~ "BRAVE_SEARCH_API_KEY"
    refute message =~ "super"
  end

  test "a saved search key equips search and guarded fetch by default", %{tmp_dir: dir} do
    path = write_config(dir, %{})
    assert {:ok, options} = Options.parse(["--config", path])
    assert options.web_search == "brave"
    assert options.web_fetch
    assert {:ok, tools} = Runtime.standard_tools(options, [])

    assert Enum.map(tools, &Tool.name/1) ==
             ~w(read grep glob write edit bash web_search web_fetch research_check todo)

    assert search_key(tools) == "saved-brave-key"

    assert {:ok, prepared} =
             Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))

    assert prepared.harness.system =~ "list the distinct facts"
    assert "web_fetch" in Enum.map(prepared.harness.tools, &Tool.name/1)

    assert {:ok, disabled} = Options.parse(["--config", path, "--web-search", "none"])
    assert disabled.web_search == nil
    refute disabled.web_fetch
    assert {:ok, plain} = Runtime.standard_tools(disabled, [])
    refute "web_search" in Enum.map(plain, &Tool.name/1)

    System.put_env("LMX_WEB_SEARCH", "none")
    assert {:ok, shell_disabled} = Options.parse(["--config", path])
    assert shell_disabled.web_search == nil
    refute shell_disabled.web_fetch

    System.delete_env("LMX_WEB_SEARCH")
    path = write_config(dir, %{"web_search" => "none"})
    assert {:ok, saved_disabled} = Options.parse(["--config", path])
    assert saved_disabled.web_search == nil
    refute saved_disabled.web_fetch
  end

  test "a credential-free host remains offline and a disabled key cannot re-enable the saved key",
       %{tmp_dir: dir} do
    assert {:ok, options} = Options.parse([])
    assert options.web_search == nil
    refute options.web_fetch

    path = write_config(dir, %{})
    System.put_env("BRAVE_SEARCH_API_KEY", "")
    assert {:ok, disabled} = Options.parse(["--config", path])
    assert disabled.web_search == nil
    refute disabled.web_fetch
  end

  test "config enables search and fetch with its saved key and environment overrides it", %{
    tmp_dir: dir
  } do
    path = write_config(dir, %{"web_search" => "brave", "web_fetch" => true})
    assert {:ok, options} = Options.parse(["--config", path])
    assert {:ok, tools} = Runtime.standard_tools(options, [])

    assert Enum.map(tools, &Tool.name/1) ==
             ~w(read grep glob write edit bash web_search web_fetch research_check todo)

    assert search_key(tools) == "saved-brave-key"
    refute inspect(options) =~ "saved-brave-key"
    descriptors = Enum.map(tools, &(Tool.descriptor(&1) |> Descriptor.to_map()))
    refute JSON.encode!(descriptors) =~ "saved-brave-key"

    System.put_env("BRAVE_SEARCH_API_KEY", "ambient-brave-key")
    assert {:ok, tools} = Runtime.standard_tools(options, [])
    assert search_key(tools) == "ambient-brave-key"

    System.put_env("BRAVE_SEARCH_API_KEY", "")
    assert {:error, reason} = Runtime.standard_tools(options, [])
    assert reason =~ "BRAVE_SEARCH_API_KEY"
    assert reason =~ "web_search_providers.brave.api_key"
    refute reason =~ "saved-brave-key"
  end

  test "a model-provider credential cannot supply the selected search backend", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "web_search" => "brave",
        "providers" => %{"brave" => %{"api_key" => "model-provider-key"}},
        "web_search_providers" => %{"other_search" => %{"api_key" => "other-search-key"}}
      })
    )

    File.chmod!(path, 0o600)
    assert {:ok, options} = Options.parse(["--config", path])
    # The file chose Brave with no Brave key: search stays off, and the
    # startup warning names the field, never what sits in the other sections.
    assert options.web_search == nil
    assert [warning] = Config.warnings(options.config)
    assert warning =~ "web_search_providers.brave.api_key"
    refute warning =~ "model-provider-key"
    refute warning =~ "other-search-key"
    assert {:ok, tools} = Runtime.standard_tools(options, [])
    refute "web_search" in Enum.map(tools, &Tool.name/1)
  end

  # Issue #3: refusing to start over an optional tool kept a person whose
  # file held an empty placeholder out of the screen altogether. The file's
  # choice is a default; the flag and the variable are orders.
  test "Brave chosen in the file without a key is a warning and no search; by flag or variable it is an error",
       %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(%{"web_search" => "brave"}))
    File.chmod!(path, 0o600)

    assert {:ok, options} = Options.parse(["--config", path])
    assert options.web_search == nil
    assert [warning] = Config.warnings(options.config)
    assert warning =~ "BRAVE_SEARCH_API_KEY"
    assert warning =~ ~s(set web_search to "none")

    # An explicitly empty variable is no key either.
    System.put_env("BRAVE_SEARCH_API_KEY", "")
    assert {:ok, %{web_search: nil}} = Options.parse(["--config", path])

    System.put_env("BRAVE_SEARCH_API_KEY", "ambient-brave-key")
    assert {:ok, %{web_search: "brave", config: keyed}} = Options.parse(["--config", path])
    assert Config.warnings(keyed) == []

    System.delete_env("BRAVE_SEARCH_API_KEY")
    assert {:ok, flagged} = Options.parse(["--config", path, "--web-search", "brave"])
    assert flagged.web_search == "brave"
    assert {:error, reason} = Runtime.standard_tools(flagged, [])
    assert reason =~ "web_search_providers.brave.api_key"

    System.put_env("LMX_WEB_SEARCH", "brave")
    assert {:ok, %{web_search: "brave"}} = Options.parse(["--config", path])
  end

  # The Elixir profile is applied over the standard catalog, so what it keeps
  # is asked of the extension directly: the interactive tool survives, the
  # network tool does not.
  test "a configured search becomes part of the standard profile but not Elixir-only mode" do
    System.put_env("BRAVE_SEARCH_API_KEY", "super-secret")
    assert {:ok, options} = Options.parse(["--web-search", "brave"])

    assert {:ok, standard} = Runtime.standard_tools(options, interactive?: true)

    assert Enum.map(standard, &Tool.name/1) ==
             ~w(read grep glob write edit bash ask_user web_search web_fetch research_check todo)

    focused = ElixirProfile.apply(Harness.new(tools: standard), [])
    assert Enum.map(focused.tools, &Tool.name/1) == ~w(elixir ask_user)

    descriptor =
      standard
      |> Enum.find(&(Tool.name(&1) == "web_search"))
      |> Tool.descriptor()
      |> Descriptor.to_map()

    encoded = JSON.encode!(descriptor)
    refute encoded =~ "super-secret"
  end

  test "a credential-backed default does not widen an explicit extension profile" do
    System.put_env("BRAVE_SEARCH_API_KEY", "super-secret")
    assert {:ok, options} = Options.parse([])
    assert Options.automatic_web?(options)

    profile = %{
      "execution" => "live",
      "model" => "test:model",
      "tools" => ["read"],
      "options" => %{
        "system" => "Read local files only.",
        "max_turns" => 3,
        "max_tokens" => 512,
        "max_cost_usd" => 0.5,
        "reasoning_effort" => "default",
        "temperature" => 0.2
      }
    }

    extension = {Profile, profile: profile, provider: Scripted.new([])}
    assert {:ok, tools} = Runtime.standard_tools(options, profile: extension)
    assert Enum.map(tools, &Tool.name/1) == ["read"]
  end

  test "resume rebinds search only when the current host configures it again", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, %{"web_search" => "brave"})
    store = JSONL.new(tmp_dir)

    assert {:ok, original_options} = Options.parse(["--config", path])
    original_supervisor = unique_supervisor("original")

    assert {:ok, original} =
             Runtime.start_session(original_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: original_supervisor
             )

    id = Session.id(original)
    assert "web_search" in Session.snapshot(original).tools

    config = original |> Session.snapshot() |> Map.fetch!(:entries) |> List.first()
    refute "Elixir.Lemieux.Tools.WebSearch" in config.payload["tools"]
    refute JSON.encode!(config.payload) =~ "saved-brave-key"
    Supervisor.stop(original_supervisor)

    assert {:ok, plain_options} = Options.parse(["--resume", id])
    plain_supervisor = unique_supervisor("plain")

    assert {:ok, plain} =
             Runtime.start_session(plain_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: plain_supervisor
             )

    refute "web_search" in Session.snapshot(plain).tools
    Supervisor.stop(plain_supervisor)

    write_config(tmp_dir, %{"web_search" => "brave"}, "changed-brave-key")
    assert {:ok, rebound_options} = Options.parse(["--resume", id, "--config", path])

    rebound_supervisor = unique_supervisor("rebound")

    assert {:ok, rebound} =
             Runtime.start_session(rebound_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: rebound_supervisor
             )

    assert "web_search" in Session.snapshot(rebound).tools
    assert search_key(:sys.get_state(rebound).tools) == "changed-brave-key"
    Supervisor.stop(rebound_supervisor)

    transcripts = Path.wildcard(Path.join(tmp_dir, "**/*.jsonl"))
    assert transcripts != []
    content = Enum.map_join(transcripts, &File.read!/1)
    refute content =~ "saved-brave-key"
    refute content =~ "changed-brave-key"
    refute content =~ "web_search_providers"
  end

  defp write_config(dir, settings, key \\ "saved-brave-key") do
    path = Path.join(dir, "config.json")
    settings = Map.put(settings, "web_search_providers", %{"brave" => %{"api_key" => key}})
    File.write!(path, JSON.encode!(settings))
    File.chmod!(path, 0o600)
    path
  end

  defp search_key(tools) do
    {Lemieux.Extensions.Web.Brave, backend} =
      tools |> Enum.find(&(Tool.name(&1) == "web_search")) |> Map.fetch!(:backend)

    backend.api_key
  end

  defp unique_supervisor(label),
    do: :"lemieux_cli_web_search_#{label}_#{System.unique_integer([:positive])}"
end
