defmodule Lemieux.CLI.SecretPathsLogsTest do
  # `Lemieux.CLI.Logs` makes `logs/` in the state directory on every start,
  # and the crash dump goes to `crash/` there. Neither counted as lmx's, so a
  # dedicated config directory (`LMX_CONFIG=~/.config/lmx/config.json`) was
  # never hidden whole again after its first run, and `logs/lmx.log` — which
  # at a verbose log level holds provider response headers — stayed in a
  # sandboxed command's reach (found in review, 2026-10).
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime.SecretPaths
  alias Lemieux.Environment.Sandbox

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    %{root: tmp_dir, work: work}
  end

  defp paths(config, state, context) do
    {:ok, options} =
      Options.parse([
        "--sandbox",
        "--config",
        config,
        "--sessions-dir",
        Path.join(context.root, "sessions")
      ])

    options = put_in(options.host.state_dir, state)
    SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)
  end

  defp config_file(dir, name \\ "config.json") do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, JSON.encode!(%{"version" => 1}))
    File.chmod!(path, 0o600)
    path
  end

  defp put(dir, name) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  defp real(path), do: Sandbox.real(path)

  test "a config directory holding its logs and a crash dump is still hidden whole", context do
    dir = Path.join(context.root, "xdg-lmx")
    config = config_file(dir)
    put(dir, "state.json")
    put(dir, "logs/lmx.log")
    put(dir, "logs/lmx.log.0")
    put(dir, "crash/erl_crash.dump")

    assert real(dir) in paths(config, dir, context)
  end

  test "beside other things, the logs and crash directories are hidden with the rest", context do
    shared = Path.join(context.root, "dot-config")
    config = config_file(shared, "lmx.json")
    put(shared, "git/config")
    put(shared, "logs/lmx.log")
    put(shared, "crash/erl_crash.dump")

    paths = paths(config, shared, context)

    refute real(shared) in paths
    assert real(config) in paths
    assert real(Path.join(shared, "logs")) in paths
    assert real(Path.join(shared, "crash")) in paths
    refute Enum.any?(paths, &Sandbox.within?(real(Path.join(shared, "git")), &1))
  end

  # `--config ./lmx.json`: the project may have a `logs/` of its own, so only
  # lmx's files in it go.
  test "in a state directory that is the work, only lmx's own log files are hidden", context do
    config = config_file(context.work, "lmx.json")
    put(context.work, "logs/app.log")
    put(context.work, "logs/lmx.log")
    put(context.work, "crash/erl_crash.dump")

    paths = paths(config, context.work, context)

    assert real(Path.join(context.work, "logs/lmx.log")) in paths
    assert real(Path.join(context.work, "crash/erl_crash.dump")) in paths
    refute real(Path.join(context.work, "logs")) in paths
    refute Enum.any?(paths, &Sandbox.within?(real(Path.join(context.work, "logs/app.log")), &1))
  end
end
