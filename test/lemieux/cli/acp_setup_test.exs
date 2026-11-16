defmodule Lemieux.CLI.ACP.SetupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.ACP.Setup

  @moduletag :tmp_dir

  test "terminal setup saves a model and private key without starting a model request", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "config.json")
    File.write!(path, ~s({"version":1,"max_requests":4}))
    File.chmod!(path, 0o600)

    output =
      capture_io(fn ->
        assert :ok =
                 Setup.main(["--config", path],
                   env: %{},
                   setup_input: fn _ -> "anthropic:claude-sonnet-5\n" end,
                   setup_password: fn _ -> ~c"fixture-key-not-a-real-credential" end
                 )
      end)

    refute output =~ "fixture-key"
    settings = JSON.decode!(File.read!(path))
    assert settings["model"] == "anthropic:claude-sonnet-5"
    assert settings["providers"]["anthropic"]["api_key"] == "fixture-key-not-a-real-credential"
    assert settings["max_requests"] == 4
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "cancelled setup preserves an existing configuration", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    before = ~s({"version":1,"model":"anthropic:claude-sonnet-5"})
    File.write!(path, before)
    File.chmod!(path, 0o600)

    capture_io(:stderr, fn ->
      assert {:error, 1} = Setup.main(["--config", path], setup_input: fn _ -> :eof end)
    end)

    assert File.read!(path) == before
  end

  test "terminal auth is versioned, capability gated, and preserves launch flags" do
    argv = ["--config", "/custom/config.json", "--max-requests", "3"]
    assert Setup.methods(1, argv, %{}) == []

    for {version, key} <- [{1, "id"}, {2, "methodId"}] do
      assert [method] = Setup.methods(version, argv, %{"auth" => %{"terminal" => true}})
      assert method[key] == "setup"
      assert method["type"] == "terminal"
      assert method["args"] == ["acp", "setup" | argv]
    end
  end
end
