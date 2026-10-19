defmodule Lemieux.Extensions.CaptureTest do
  # Standard error capture is VM-global and must not overlap other CLI cases.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Lemieux.CLI
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Capture
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  test "a stock CLI run retains the original failing input and a distinct recovery", %{
    tmp_dir: dir
  } do
    {workspace, state, config} = fixture(dir)

    provider =
      Scripted.new([
        Scripted.tool_call("failed", "bash", %{"command" => "sh tests/run.sh"}),
        Scripted.tool_call("repair", "bash", %{"command" => "printf fixed > value"}),
        Scripted.tool_call("recovered", "bash", %{"command" => "sh tests/run.sh"}),
        Scripted.complete("done")
      ])

    assert capture_io(fn ->
             capture_io(:stderr, fn ->
               assert :ok =
                        CLI.run(["run", "--config", config, "--no-delegate", "repair the check"],
                          provider: provider,
                          cwd: workspace,
                          state_dir: state,
                          sessions_dir: Path.join(dir, "sessions")
                        )
             end)
           end) =~ "done"

    assert File.read!(Path.join(workspace, "value")) == "fixed"
    assert length(Scripted.requests(provider)) == 4
    assert {:ok, [record]} = Capture.history(Path.join(state, "capture"), workspace)
    assert record["kind"] == "verification_recovery"
    assert Enum.map(record["observations"], & &1["exit_status"]) == [1, 0]
    assert record["qualification"] == "mechanical_observation"
    assert record["replay"]["eligible"] == false
    replay_dir = Path.join(dir, "replay")
    assert {:ok, input} = Capture.materialize(record, replay_dir)
    assert File.read!(Path.join(input, "value")) == "broken"
    assert {_, 1} = System.cmd("sh", ["tests/run.sh"], cd: input)

    assert {:ok, verified} =
             Capture.validate_replay(record, replay_dir <> "-checked", fn path, command ->
               {_output, status} = System.cmd("sh", ["-c", command], cd: path)
               {:ok, status}
             end)

    assert verified["replay"]["eligible"] == true
  end

  test "unresolved failures remain distinct from recoveries and duplicate delivery is idempotent",
       %{tmp_dir: dir} do
    {workspace, state, config} = fixture(dir)

    provider =
      Scripted.new([
        Scripted.tool_call("failed", "bash", %{"command" => "sh tests/run.sh"}),
        Scripted.complete("done")
      ])

    run(config, workspace, state, dir, provider)
    assert {:ok, [record]} = Capture.history(Path.join(state, "capture"), workspace)
    assert record["kind"] == "verification_failure"
    assert :ok = Capture.retain(Path.join(state, "capture"), record)
    assert {:ok, [^record]} = Capture.history(Path.join(state, "capture"), workspace)
  end

  test "healthy work and personal or project opt out produce no capture records", %{tmp_dir: dir} do
    for mode <- [:healthy, :personal, :project] do
      root = Path.join(dir, Atom.to_string(mode))
      {workspace, state, config} = fixture(root)

      if mode == :personal,
        do:
          File.write!(
            config,
            JSON.encode!(%{
              "capture" => false,
              "permissions" => %{"mode" => "full_auto"},
              "verify" => false
            })
          )

      if mode == :project do
        File.mkdir_p!(Path.join(workspace, ".lmx"))
        File.write!(Path.join(workspace, ".lmx/capture.json"), ~s({"enabled":false}))
      end

      script =
        if mode == :healthy,
          do: [Scripted.complete("done")],
          else: [
            Scripted.tool_call("failed", "bash", %{"command" => "sh tests/run.sh"}),
            Scripted.complete("done")
          ]

      run(config, workspace, state, root, Scripted.new(script))
      assert {:ok, []} = Capture.history(Path.join(state, "capture"), workspace)
      refute File.exists?(Path.join(state, "capture"))
    end
  end

  test "capture is first party and an embedding dependency starts no capture process", %{
    tmp_dir: dir
  } do
    {workspace, state, config} = fixture(dir)
    assert {:ok, options} = Options.parse(["--config", config])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               cwd: workspace,
               state_dir: state,
               provider: Scripted.new([])
             )

    assert Enum.any?(prepared.harness.applied, &(&1["module"] == "Lemieux.Extensions.Capture"))
    refute File.exists?(Path.join(state, "capture"))
    assert Application.spec(:lemieux, :mod) in [nil, []]
  end

  test "capture configuration validates bounds and shipped opt out", %{tmp_dir: dir} do
    {workspace, state, config} = fixture(dir)

    for value <- [
          %{"max_files" => 0},
          %{"timeout_ms" => 2001},
          %{"retention_days" => "forever"},
          %{"unknown" => 1}
        ] do
      File.write!(config, JSON.encode!(%{"capture" => value}))
      assert {:error, _} = Options.parse(["--config", config])
    end

    File.write!(config, JSON.encode!(%{"disabled_extensions" => ["capture"]}))
    assert {:ok, options} = Options.parse(["--config", config])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               cwd: workspace,
               state_dir: state,
               provider: Scripted.new([])
             )

    refute Enum.any?(prepared.harness.applied, &(&1["module"] == "Lemieux.Extensions.Capture"))
  end

  defp run(config, workspace, state, dir, provider) do
    capture_io(fn ->
      capture_io(:stderr, fn ->
        assert :ok =
                 CLI.run(["run", "--config", config, "--no-delegate", "check the workspace"],
                   provider: provider,
                   cwd: workspace,
                   state_dir: state,
                   sessions_dir: Path.join(dir, "sessions")
                 )
      end)
    end)
  end

  defp fixture(dir) do
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "tests"))
    File.write!(Path.join(workspace, "value"), "broken")
    File.write!(Path.join(workspace, "tests/run.sh"), "test \"$(cat value)\" = fixed\n")
    config = Path.join(dir, "config.json")

    File.write!(
      config,
      JSON.encode!(%{"permissions" => %{"mode" => "full_auto"}, "verify" => false})
    )

    {workspace, Path.join(dir, "state"), config}
  end
end
