defmodule Lemieux.CLI.DiagnosticsBlankEnvironmentTest do
  # `lmx explain`'s diagnostics read the `LMX_*` variables as
  # `Lemieux.CLI.Options` and `Lemieux.CLI.Limits` do (`Options.env/1`): a
  # blank one is unset. Read with `System.get_env/1`, a blank `LMX_MAX_TURNS`
  # was listed as set though no limit came from it, and a blank `LMX_CONFIG`
  # was reported as the file `""`. The process environment is global, so
  # these run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Diagnostics
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime

  @moduletag :tmp_dir

  @names ~w(LMX_CONFIG LMX_MODEL LMX_MAX_TURNS LMX_MAX_REQUESTS LMX_MAX_COST_USD)

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp environment(dir) do
    output =
      capture_io(fn ->
        assert :ok = CLI.run(["explain", "--config", "none", "--no-delegate"], cwd: dir)
      end)

    JSON.decode!(output)["diagnostics"]["configuration"]["environment"]
  end

  test "a blank variable is not listed as set; one with a value is", %{tmp_dir: dir} do
    System.put_env("LMX_MODEL", " ")
    System.put_env("LMX_MAX_TURNS", "")
    System.put_env("LMX_MAX_COST_USD", "")

    assert environment(dir) == []

    System.put_env("LMX_MAX_TURNS", "7")
    assert environment(dir) == ["LMX_MAX_TURNS"]
  end

  # `--config none` here only so that preparing reads no personal file; the
  # report is then asked about a run that named no config at all.
  test "a blank LMX_CONFIG is the default file, not the file \"\"", %{tmp_dir: dir} do
    {:ok, options} = Options.parse(["--config", "none", "--no-delegate"], command: :explain)
    {:ok, prepared} = Runtime.prepare(options, cwd: dir)

    System.put_env("LMX_CONFIG", "")
    report = Diagnostics.report(%{options | given: []}, prepared)

    assert report["configuration"]["file"] == Config.default_path()
  end
end
