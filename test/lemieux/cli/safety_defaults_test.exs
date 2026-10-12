defmodule Lemieux.CLI.SafetyDefaultsTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "default CLI policy is bounded automatic operation" do
    assert {:ok, options} = Options.parse(["--config", "none"])
    assert options.host.permission_mode == "auto"
    assert {:ok, handle} = Runtime.permissions(options, [])
    assert Permissions.mode(handle) == :auto
  end

  test "without a sandbox unattended commands are refused", %{tmp_dir: dir} do
    runtime = :"safe_cli_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    assert {:ok, options} = Options.parse(["--config", "none", "--no-sandbox", "--no-delegate"])

    provider =
      Scripted.new([
        Scripted.tool_call("command", "bash", %{"command" => "printf unsafe > marker"}),
        Scripted.complete("refused")
      ])

    assert {:ok, session} =
             Runtime.start_session(options,
               supervisor: runtime,
               store: JSONL.new(Path.join(dir, "sessions")),
               cwd: dir,
               provider: provider
             )

    assert {:ok, %{stop_reason: :stop, entries: entries}} =
             Lemieux.Testing.prompt(session, "work")

    refute File.exists?(Path.join(dir, "marker"))
    assert Enum.any?(entries, &(&1.type == :tool_result and &1.payload["outcome"] == "denied"))
  end

  test "unrestricted execution requires an explicit choice", %{tmp_dir: dir} do
    assert {:ok, options} = Options.parse(["--config", "none", "--permission-mode", "full_auto"])

    assert {:ok, prepared} =
             Runtime.prepare(options, cwd: dir, provider: Scripted.new([]), store: JSONL.new(dir))

    assert Permissions.mode(prepared.permissions) == :full_auto
    refute Sandbox.sandboxed?(prepared.harness.environment)
  end

  test "an explicit host environment remains the execution authority", %{tmp_dir: dir} do
    assert {:ok, options} = Options.parse(["--config", "none"])
    environment = Local.new(credentials: :inherit)

    assert {:ok, prepared} =
             Runtime.prepare(options,
               cwd: dir,
               environment: environment,
               provider: Scripted.new([]),
               store: JSONL.new(dir)
             )

    assert prepared.harness.environment == environment
    assert Permissions.mode(prepared.permissions) == :auto
  end
end
