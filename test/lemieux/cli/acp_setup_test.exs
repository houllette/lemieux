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

  if not match?({:win32, _}, :os.type()) do
    test "terminal setup accepts a key without echoing it on a controlling terminal", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "config.json")
      File.write!(path, "{}")
      key = "offline-setup-fixture"
      model = "anthropic:claude-sonnet-5"

      replies =
        JSON.encode!([
          ["Model (provider:model)", model <> "\n"],
          ["Provider API key", key <> "\r"]
        ])

      fixture = Path.expand("../../fixtures/run_pty.py", __DIR__)

      {report, 0} =
        System.cmd(
          "python3",
          [
            fixture,
            "--respond",
            replies,
            System.find_executable("mix"),
            "run",
            "--no-compile",
            "--no-deps-check",
            "-e",
            ":ok = Lemieux.CLI.ACP.Setup.main(System.argv(), env: %{})",
            "--",
            "--config",
            path
          ],
          env: [{"MIX_ENV", "test"}, {"TERM", "xterm-256color"}]
        )

      %{"status" => status, "output" => encoded} = JSON.decode!(report)
      output = Base.decode64!(encoded)
      assert status == 0, inspect(output)
      refute output =~ key

      assert %{"providers" => %{"anthropic" => %{"api_key" => ^key}}} =
               JSON.decode!(File.read!(path))
    end
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

    assert [%{"type" => "terminal", "methodId" => "setup"}] =
             Setup.methods(2, argv, %{"auth" => %{"terminal" => %{}}})
  end
end
