defmodule Lemieux.ExtensionBuildTest do
  use ExUnit.Case, async: true

  alias Lemieux.Learning.Extension.Build

  @moduletag :tmp_dir

  setup_all do
    %{runtime: LemieuxTest.FrozenRuntime.create()}
  end

  test "explicit dependency runtimes cannot supply stale extension BEAMs", %{
    tmp_dir: root,
    runtime: runtime
  } do
    source = source(root)
    stale = Path.join(root, "stale/ebin")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "Elixir.FrozenExample.beam"), "stale compiled extension")

    assert {:error, :extension_module_in_runtime} =
             Build.freeze(source, Path.join(root, "frozen"), profile(),
               runtime_paths: runtime ++ [stale]
             )

    refute File.exists?(Path.join(root, "frozen"))
  end

  test "live profiles need explicit caps and dispatch authorization", %{
    tmp_dir: root,
    runtime: runtime
  } do
    source = source(root)
    live = %{profile() | "execution" => "live"}

    assert {:error, :invalid_frozen_profile} =
             Build.freeze(source, Path.join(root, "missing-budget"), live, runtime_paths: runtime)

    live = put_in(live, ["options", "max_cost_usd"], 0.1)

    assert {:ok, build} =
             Build.freeze(source, Path.join(root, "bounded"), live, runtime_paths: runtime)

    assert {:error, :live_confirmation_required} =
             Build.run(build, %{prompt: "x", cwd: source, timeout_ms: 5000})

    secret = put_in(live, ["options", "api_key"], "do-not-persist")

    assert {:error, :invalid_frozen_profile} =
             Build.freeze(source, Path.join(root, "secret"), secret, runtime_paths: runtime)

    refute File.exists?(Path.join(root, "secret"))
  end

  test "failed consumers retain partial paid observations", %{tmp_dir: root, runtime: runtime} do
    source = source(root)
    file = Path.join(source, "lib/example.ex")

    File.write!(file, """
    defmodule FrozenExample do
      def configure(profile), do: {:ok, [], profile}
      def run(_input, _opts), do: {:error, :budget_exhausted, %{"status" => "failed", "answer" => "partial", "usage" => %{"cost_usd" => 0.02}}}
    end
    """)

    assert {:ok, build} =
             Build.freeze(source, Path.join(root, "frozen"), profile(), runtime_paths: runtime)

    assert {:error, {:frozen_agent, _}, observation} =
             Build.run(build, %{prompt: "x", cwd: source, timeout_ms: 5000})

    assert observation["usage"]["cost_usd"] == 0.02
    assert observation["answer"] == "partial"
    assert observation["frozen_build_sha256"] == build.sha256
  end

  test "frozen source and profile execute in a fresh consumer and reject drift", %{
    tmp_dir: root,
    runtime: runtime
  } do
    source = source(root)
    profile = profile()

    assert {:ok, build} =
             Build.freeze(source, Path.join(root, "frozen"), profile, runtime_paths: runtime)

    input = %{prompt: "hello", cwd: source, timeout_ms: 10_000}
    assert {:ok, %{"answer" => "frozen hello"}} = Build.run(build, input)
    File.write!(Path.join(source, "lib/example.ex"), "invalid new source")
    assert {:ok, %{"answer" => "frozen hello"}} = Build.run(build, input)
    assert :ok = Build.verify(build)

    File.write!(Path.join(build.root, "source/lib/example.ex"), "different")
    assert {:error, :frozen_tree_changed} = Build.run(build, input)
  end

  test "profile and dependency mutations invalidate a pinned build", %{
    tmp_dir: root,
    runtime: runtime
  } do
    for {name, relative} <- [
          {"profile", "profile.json"},
          {"dependency", "runtime/lemieux/ebin/Elixir.Lemieux.Agent.beam"}
        ] do
      assert {:ok, build} =
               Build.freeze(
                 source(Path.join(root, name)),
                 Path.join(root, name <> "-build"),
                 profile(),
                 runtime_paths: runtime
               )

      File.write!(Path.join(build.root, relative), "changed")
      assert {:error, :frozen_tree_changed} = Build.verify(build)
    end
  end

  test "configuration must resolve to the frozen effective profile", %{
    tmp_dir: root,
    runtime: runtime
  } do
    source = source(root)
    path = Path.join(source, "lib/example.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "{:ok, [], profile}",
        "{:ok, [], Map.put(profile, \"model\", \"other\")}"
      )
    )

    assert {:ok, build} =
             Build.freeze(source, Path.join(root, "frozen"), profile(), runtime_paths: runtime)

    assert {:error, {:consumer_failed, _}} =
             Build.run(build, %{prompt: "x", cwd: source, timeout_ms: 10_000})
  end

  defp profile,
    do: %{"execution" => "scripted", "model" => "none", "tools" => [], "options" => %{}}

  defp source(root) do
    source = Path.join(root, "project")
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "# preserved Mix source\n")

    File.write!(Path.join(source, "lib/example.ex"), """
    defmodule FrozenExample do
      def configure(profile), do: {:ok, [], profile}
      def run(input, _opts), do: {:ok, %{"status" => "completed", "answer" => "frozen " <> input.prompt}}
    end
    """)

    File.write!(
      Path.join(source, "lemieux-extension.json"),
      JSON.encode!(%{
        "schema_version" => 1,
        "module" => "FrozenExample",
        "files" => ["mix.exs", "lib/example.ex"]
      })
    )

    source
  end
end
