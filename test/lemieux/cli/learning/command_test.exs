defmodule Lemieux.CLI.Learning.CommandTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Lemieux.CLI.Learning.Command
  @moduletag :tmp_dir

  test "inspect and persistent controls need no configured provider", %{tmp_dir: dir} do
    config = Path.join(dir, "config.json")
    File.write!(config, JSON.encode!(%{"version" => 1, "model" => "unavailable:model"}))
    opts = [cwd: dir, provider: fn -> flunk("inspection must not resolve a provider") end]

    invoke = fn args ->
      capture_io(fn -> assert :ok = Command.run(args ++ ["--config", config], opts) end)
      |> JSON.decode!()
    end

    assert invoke.(["inspect"])["enabled"]
    refute invoke.(["off"])["enabled"]
    refute invoke.([])["enabled"]
    assert invoke.(["on"])["enabled"]
    assert invoke.([])["retained"] == 0

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} = Command.run(["undo", "--config", config], opts)
      end)

    assert stderr =~ "no_task_local_adaptation"
  end
end
