defmodule Lmx.SystemOneCompactionTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, Diagnostics, Options, Runtime, SystemOneCompaction}
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # Every test clears JEV_API_KEY first: a hosted key in the contributor's
  # shell would otherwise be the provider TypeSafe is chosen by.
  setup do
    previous = System.get_env("JEV_API_KEY")
    System.delete_env("JEV_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("JEV_API_KEY", previous),
        else: System.delete_env("JEV_API_KEY")
    end)
  end

  test "a hosted TypeSafe key enables compaction with no configuration" do
    System.put_env("JEV_API_KEY", "hosted-test-key")

    assert {:ok, {LemieuxSystemOneCompaction, opts}} =
             SystemOneCompaction.spec(%Config{}, nil)

    assert client = LemieuxSystemOneCompaction.client(opts)
    assert client.provider == SystemOneSDK.Providers.TypeSafe
    assert client.base_url == "https://api.typesafe.ai"
    assert client.api_key == "hosted-test-key"
  end

  # The config tests load a file holding a key, which Lemieux.CLI.Config
  # accepts only with owner-only Unix permissions; Windows reports 0666.
  @tag :unix
  test "the shipped host assembles the step from an Ixway provider in the personal config", %{
    tmp_dir: dir
  } do
    path =
      write_config(dir, %{
        "version" => 1,
        "ixway" => %{
          "enabled" => false,
          "endpoint" => "http://localhost:4003",
          "api_key" => "private-test-gateway-key"
        },
        "systemone_compaction" => %{"mode" => "apply", "provider" => "ixway"},
        "systemone_providers" => %{"ixway" => %{"model" => "gateway-scorer-1"}}
      })

    assert {:ok, options} = Options.parse(["--config", path, "--no-delegate"])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               provider: Scripted.new([]),
               store: JSONL.new(dir),
               tools: [Lemieux.Tools.Read]
             )

    assert %{"options" => %{"provider" => "ixway"}} =
             Enum.find(prepared.harness.applied, &(&1["module"] == "LemieuxSystemOneCompaction"))

    # The step's hook is one of the request-preparation hooks; the plan tool
    # and MCP discovery add their own beside it.
    hooks = Keyword.get_values(prepared.harness.hooks, :prepare_next_turn)
    assert Enum.count(hooks, &(inspect(&1) =~ "LemieuxSystemOneCompaction")) == 1
    refute inspect(prepared.harness.applied) =~ "private-test-gateway-key"
  end

  @tag :unix
  test "a declared System One endpoint takes the vendors' place, with nothing for either", %{
    tmp_dir: dir
  } do
    # Both vendors are fully configured beside it, and neither is used.
    System.put_env("JEV_API_KEY", "hosted-key-that-must-not-be-used")

    path =
      write_config(dir, %{
        "version" => 1,
        "ixway" => %{
          "enabled" => false,
          "endpoint" => "http://localhost:4003",
          "api_key" => "gateway-key-that-must-not-be-used"
        },
        "systemone_compaction" => %{"mode" => "apply", "provider" => "local"},
        "systemone_providers" => %{
          "typesafe" => %{"api_key" => "saved-key-that-must-not-be-used"},
          "ixway" => %{"model" => "gateway-scorer-1"},
          "local" => %{
            "base_url" => "http://127.0.0.1:8080/scorer",
            "model" => "local-scorer-1",
            "headers" => %{"X-Scorer-Tenant" => "team-a"},
            "input_per_million" => 0.05,
            "output_per_million" => 0
          }
        }
      })

    assert {:ok, options} = Options.parse(["--config", path, "--no-delegate"])

    assert {:ok, {LemieuxSystemOneCompaction, opts}} =
             SystemOneCompaction.spec(options.config, options.ixway)

    # The SDK's generic endpoint client, for that URL, with no credential at all.
    client = LemieuxSystemOneCompaction.client(opts)
    assert client.provider == SystemOneSDK.Providers.Endpoint
    assert client.base_url == "http://127.0.0.1:8080/scorer"
    assert client.api_key == nil
    assert client.default_model == "local-scorer-1"
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
             Enum.find(prepared.harness.applied, &(&1["module"] == "LemieuxSystemOneCompaction"))

    refute inspect(prepared.harness.applied) =~ "must-not-be-used"
    refute inspect(opts) =~ "must-not-be-used"

    # `lmx explain` says where the scorer's requests go, by name only.
    report = Diagnostics.report(options, prepared)
    assert report["systemone_compaction"] == %{"mode" => "apply", "provider" => "local"}
    refute JSON.encode!(report) =~ "127.0.0.1:8080"
  end

  test "a declared provider that is not selected leaves the step off, and a selected incomplete one stops an apply start" do
    local = %{"base_url" => "http://127.0.0.1:8080", "model" => "local-scorer-1"}

    declared = %Config{settings: %{"systemone_providers" => %{"local" => local}}}
    assert SystemOneCompaction.spec(declared, nil) == {:ok, nil}

    incomplete = %Config{
      settings: %{
        "systemone_compaction" => %{"mode" => "apply", "provider" => "local"},
        "systemone_providers" => %{"local" => Map.delete(local, "model")}
      }
    }

    assert {:error, message} = SystemOneCompaction.spec(incomplete, nil)

    assert message =~
             "System One compaction is set to apply, but the local provider has no model"

    assert message =~ "systemone_providers entry."

    # In auto mode the same incomplete selection is simply off.
    auto = put_in(incomplete.settings, ["systemone_compaction", "mode"], "auto")
    assert SystemOneCompaction.spec(%Config{settings: auto}, nil) == {:ok, nil}
  end

  @tag :unix
  test "a TypeSafe key saved in the personal config enables the hosted provider", %{
    tmp_dir: dir
  } do
    path =
      write_config(dir, %{
        "version" => 1,
        "systemone_providers" => %{"typesafe" => %{"api_key" => "private-hosted-key"}}
      })

    assert {:ok, config} = Config.load(path)

    assert {:ok, {LemieuxSystemOneCompaction, opts}} = SystemOneCompaction.spec(config, nil)
    assert LemieuxSystemOneCompaction.client(opts).api_key == "private-hosted-key"
    refute inspect(config) =~ "private-hosted-key"
  end

  defp write_config(dir, settings) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(settings))
    File.chmod!(path, 0o600)
    path
  end
end
