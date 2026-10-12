defmodule Lemieux.CLI.SandboxUnavailableTest do
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "implicit fallback retains approvals while an explicit sandbox fails closed", %{
    tmp_dir: dir
  } do
    original = System.get_env("PATH")

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)

    System.put_env("PATH", dir)
    opts = [cwd: dir, provider: Scripted.new([]), store: JSONL.new(dir)]
    assert {:ok, options} = Options.parse(["--config", "none", "--no-delegate"])
    assert {:ok, prepared} = Runtime.prepare(options, opts)
    assert Permissions.mode(prepared.permissions) == :auto
    refute Sandbox.sandboxed?(prepared.harness.environment)

    assert Enum.any?(
             prepared.harness.notices,
             &String.contains?(&1, "commands and external capabilities require approval")
           )

    assert {:ok, explicit} = Options.parse(["--config", "none", "--sandbox", "--no-delegate"])
    assert {:error, reason} = Runtime.prepare(explicit, opts)
    assert reason =~ "sandbox could not start"
  end
end
