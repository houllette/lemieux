defmodule Lmx.JevCompactionTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.{Config, JevCompaction, Options, Runtime}
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
