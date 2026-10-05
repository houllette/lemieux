defmodule Mix.Tasks.Lemieux.Extension.EvalTest do
  # The task used to start a live comparison as soon as it was asked, while
  # every sibling (workbench, compare, confirm, discovery) refused without an
  # explicit live flag; a configuration that names a hosted model spends money.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lemieux.Extension.Eval

  @moduletag :tmp_dir

  # A suite that does not exist: a run that got past the live check fails on
  # reading it, before any agent starts, so no test here reaches a provider.
  defp config!(dir, execution) do
    path = Path.join(dir, "compare.exs")
    suite = Path.join(dir, "missing-suite.json")
    execution = if execution == :unset, do: "", else: "execution: #{inspect(execution)},"

    File.write!(path, """
    [#{execution} suite: #{inspect(suite)}, agents: []]
    """)

    path
  end

  test "a live configuration is refused without --allow-live", %{tmp_dir: dir} do
    for execution <- [:unset, :live] do
      error = assert_raise Mix.Error, fn -> Eval.run([config!(dir, execution)]) end
      assert error.message =~ "--allow-live"
      refute error.message =~ "Extension evaluation failed"
    end
  end

  test "--allow-live lets a live configuration run", %{tmp_dir: dir} do
    error =
      assert_raise Mix.Error, fn -> Eval.run([config!(dir, :live), "--allow-live"]) end

    assert error.message =~ "Extension evaluation failed"
  end

  test "a scripted configuration runs without the flag", %{tmp_dir: dir} do
    error = assert_raise Mix.Error, fn -> Eval.run([config!(dir, :scripted)]) end
    assert error.message =~ "Extension evaluation failed"
  end

  test "an unknown execution mode is refused rather than treated as offline",
       %{tmp_dir: dir} do
    error =
      assert_raise Mix.Error, fn -> Eval.run([config!(dir, :offline), "--allow-live"]) end

    assert error.message =~ ":execution"
  end

  test "an unknown switch is a usage error, not a live run", %{tmp_dir: dir} do
    error =
      assert_raise Mix.Error, fn -> Eval.run([config!(dir, :live), "--allow-lvie"]) end

    assert error.message =~ "Usage: mix lemieux.extension.eval CONFIG.exs [--allow-live]"
  end
end
