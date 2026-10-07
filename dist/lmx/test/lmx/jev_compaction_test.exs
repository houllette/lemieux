defmodule Lmx.JevCompactionTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, Diagnostics, JevCompaction, Options, Runtime}
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "a hosted Jev key enables compaction with no configuration" do
    previous = System.get_env("JEV_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("JEV_API_KEY", previous),
        else: System.delete_env("JEV_API_KEY")
    end)

    System.put_env("JEV_API_KEY", "hosted-test-key")
    assert {:ok, {LemieuxJevCompaction, opts}} = JevCompaction.spec(%Config{}, nil)
    assert client = LemieuxJevCompaction.client(opts)
    assert client.base_url == "https://api.typesafe.ai"
    assert client.api_key == "hosted-test-key"
  end

  # Both config tests load a file holding a key, which Lemieux.CLI.Config
  # accepts only with owner-only Unix permissions; Windows reports 0666.
  @tag :unix
  test "the shipped host assembles Jev from an Ixway route in the personal config", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "ixway" => %{
          "enabled" => false,
          "endpoint" => "http://localhost:4003",
          "api_key" => "private-test-gateway-key"
        },
        "jev_compaction" => %{
          "mode" => "apply",
          "route" => "ixway",
          "model" => "jev-local-1",
          "endpoint" => "http://localhost:4003"
        }
      })
    )

    File.chmod!(path, 0o600)

    assert {:ok, options} = Options.parse(["--config", path, "--no-delegate"])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               provider: Scripted.new([]),
               store: JSONL.new(dir),
               tools: [Lemieux.Tools.Read]
             )

    assert Enum.any?(prepared.harness.applied, &(&1["module"] == "LemieuxJevCompaction"))
    # Jev's hook is one of the request-preparation hooks; the plan tool and
    # MCP discovery add their own beside it.
    hooks = Keyword.get_values(prepared.harness.hooks, :prepare_next_turn)
    assert Enum.count(hooks, &(inspect(&1) =~ "LemieuxJevCompaction")) == 1
    refute inspect(prepared.harness.applied) =~ "private-test-gateway-key"
  end

  # Both tests clear JEV_API_KEY: a hosted key in the contributor's shell
  # would otherwise be the provider TypeSafe is chosen by.
  test "a declared System One endpoint takes the vendors' place, with nothing for either", %{
    tmp_dir: dir
  } do
    # Both vendors are fully configured beside it, and neither is used.
    without_hosted_key()
    System.put_env("JEV_API_KEY", "hosted-key-that-must-not-be-used")
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "ixway" => %{
          "enabled" => false,
          "endpoint" => "http://localhost:4003",
          "api_key" => "gateway-key-that-must-not-be-used"
        },
        "jev_compaction" => %{"mode" => "apply", "provider" => "local", "model" => "jev-local-1"},
        "jev_compaction_providers" => %{
          "local" => %{
            "base_url" => "http://127.0.0.1:8080/scorer",
            "model" => "jev-local-1",
            "headers" => %{"X-Scorer-Tenant" => "team-a"},
            "input_per_million" => 0.05,
            "output_per_million" => 0
          }
        }
      })
    )

    File.chmod!(path, 0o600)
    assert {:ok, options} = Options.parse(["--config", path, "--no-delegate"])
    assert {:ok, {LemieuxJevCompaction, opts}} = JevCompaction.spec(options.config, options.ixway)

    # The SDK's generic endpoint client, for that URL, with no credential at all.
    client = LemieuxJevCompaction.client(opts)
    assert client.provider == SystemOneSDK.Providers.Endpoint
    assert client.base_url == "http://127.0.0.1:8080/scorer"
    assert client.api_key == nil
    assert client.default_model == "jev-local-1"
    assert client.headers["X-Scorer-Tenant"] == "team-a"
    assert opts[:input_per_million] == 0.05
    assert opts[:output_per_million] == 0

    assert {:ok, prepared} =
             Runtime.prepare(options,
               provider: Scripted.new([]),
               store: JSONL.new(dir),
               tools: [Lemieux.Tools.Read]
             )

    assert %{"options" => %{"enabled" => true, "mode" => "apply", "provider" => "local"}} =
             Enum.find(prepared.harness.applied, &(&1["module"] == "LemieuxJevCompaction"))

    refute inspect(prepared.harness.applied) =~ "must-not-be-used"
    refute inspect(opts) =~ "must-not-be-used"

    # `lmx explain` says where the scorer's requests go, by name only.
    report = Diagnostics.report(options, prepared)
    assert report["jev_compaction"] == %{"mode" => "apply", "provider" => "local"}
    refute JSON.encode!(report) =~ "127.0.0.1:8080"
  end

  test "a declared provider that is not selected leaves the step off, and a selected incomplete one stops an apply start" do
    without_hosted_key()
    local = %{"base_url" => "http://127.0.0.1:8080", "model" => "jev-local-1"}

    declared = %Config{settings: %{"jev_compaction_providers" => %{"local" => local}}}
    assert JevCompaction.spec(declared, nil) == {:ok, nil}

    incomplete = %Config{
      settings: %{
        "jev_compaction" => %{"mode" => "apply", "provider" => "local"},
        "jev_compaction_providers" => %{"local" => Map.delete(local, "model")}
      }
    }

    assert {:error, message} = JevCompaction.spec(incomplete, nil)
    assert message =~ "Jev compaction is set to apply, but the local provider has no model"
    assert message =~ "jev_compaction_providers entry."

    # In auto mode the same incomplete selection is simply off.
    auto = put_in(incomplete.settings, ["jev_compaction", "mode"], "auto")
    assert JevCompaction.spec(%Config{settings: auto}, nil) == {:ok, nil}
  end

  defp without_hosted_key do
    previous = System.get_env("JEV_API_KEY")
    System.delete_env("JEV_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("JEV_API_KEY", previous),
        else: System.delete_env("JEV_API_KEY")
    end)
  end

  @tag :unix
  test "a key saved in the personal config enables the hosted Jev route", %{tmp_dir: dir} do
    previous = System.get_env("JEV_API_KEY")
    System.delete_env("JEV_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("JEV_API_KEY", previous),
        else: System.delete_env("JEV_API_KEY")
    end)

    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "jev_compaction" => %{"api_key" => "private-hosted-key"}})
    )

    File.chmod!(path, 0o600)

    assert {:ok, config} = Config.load(path)
    assert {:ok, {LemieuxJevCompaction, opts}} = JevCompaction.spec(config, nil)
    assert LemieuxJevCompaction.client(opts).api_key == "private-hosted-key"
    refute inspect(config) =~ "private-hosted-key"
  end
end
