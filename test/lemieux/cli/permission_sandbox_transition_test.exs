defmodule Lemieux.CLI.PermissionSandboxTransitionTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{Options, Runtime}
  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  test "the implicit sandbox follows full-auto and restores protection on the next operation", %{
    tmp_dir: dir
  } do
    protected = Path.join(dir, "protected")
    File.mkdir_p!(protected)
    File.write!(Path.join(protected, "fixture"), "fixture")
    {:ok, options} = Options.parse(["--config", "none", "--bare", "--no-delegate"])

    {:ok, prepared} =
      Runtime.prepare(options, cwd: dir, store: JSONL.new(protected), provider: Scripted.new([]))

    environment = prepared.harness.environment

    if Sandbox.sandboxed?(environment) do
      assert Environment.read_file(environment, dir, "protected/fixture") == {:error, :eacces}
      command = "cat " <> LemieuxTest.Shell.quoted(Path.join(protected, "fixture"))

      assert {:ok, already_started} =
               Environment.run(environment, command, cwd: dir, timeout_ms: 5000)

      :ok = Permissions.set_mode(prepared.permissions, :full_auto)
      # The stream selected before the switch retains its original command wrapper.
      events_before_switch = Enum.to_list(already_started)
      assert {:exit_status, 1} in events_before_switch
      refute {:data, "fixture"} in events_before_switch
      refute Sandbox.sandboxed?(environment)
      assert Sandbox.describe(environment) == nil
      assert {:ok, "fixture"} = Environment.read_file(environment, dir, "protected/fixture")

      assert {:ok, events} =
               Environment.run(
                 environment,
                 "cat " <> LemieuxTest.Shell.quoted(Path.join(protected, "fixture")),
                 cwd: dir,
                 timeout_ms: 5000
               )

      assert Enum.to_list(events) |> Enum.any?(&(&1 == {:data, "fixture"}))
      :ok = Permissions.set_mode(prepared.permissions, :auto)
      assert Sandbox.sandboxed?(environment)
      assert Environment.read_file(environment, dir, "protected/fixture") == {:error, :eacces}
    else
      assert Enum.any?(prepared.notices, &String.contains?(&1, "No OS sandbox"))
    end
  end

  test "an explicit sandbox retains host authority", %{tmp_dir: dir} do
    {:ok, options} = Options.parse(["--config", "none", "--bare", "--no-delegate", "--sandbox"])

    case Runtime.prepare(options,
           cwd: dir,
           store: JSONL.new(Path.join(dir, "sessions")),
           provider: Scripted.new([])
         ) do
      {:ok, prepared} ->
        :ok = Permissions.set_mode(prepared.permissions, :full_auto)
        assert Sandbox.sandboxed?(prepared.harness.environment)

      {:error, reason} ->
        assert reason =~ "sandbox could not start"
    end
  end
end
