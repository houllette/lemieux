defmodule Lemieux.ExtensionFrozenBuildTest do
  # Freezing dependency beams and booting a second VM contend with the rest of
  # the suite on CI's small runner. Run this integration test after async cases.
  use ExUnit.Case

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Builder
  alias Lemieux.Learning.Builder.Scaffold
  alias Lemieux.Learning.Extension.Build

  @moduletag :tmp_dir
  @tag timeout: 180_000
  test "quota scaffold compiles from frozen source and preserves workflow tools", context do
    source = Path.join(context.tmp_dir, "source")
    profile = Builder.profile("test:model") |> Profile.quota(2)
    assert {:ok, _} = Scaffold.create(source, "frozen_builder", profile)
    # Scripted provider injection is explicit fixture code, not real efficacy.
    file = Path.join(source, "lib/frozen_builder.ex")

    body =
      File.read!(file)
      |> String.replace(
        "def configure(profile), do: configure(profile, [])",
        """
        def configure(profile) do
          provider = Lemieux.Providers.Scripted.new([
            Lemieux.Providers.Scripted.tool_call("guide", "extension_workflow", %{"action" => "guide"}, usage: %{"cost_usd" => 0.001}),
            Lemieux.Providers.Scripted.complete("frozen builder ready")
          ], estimated_cost_usd: 0.001)
          Lemieux.Extension.Profile.configure(profile, provider: provider)
        end
        """
      )

    File.write!(file, body)
    {:ok, build} = Build.freeze(source, Path.join(context.tmp_dir, "frozen"), profile)

    # The frozen runtime copies every dependency's beams, some 80 MB, and
    # ExUnit leaves a test's tmp_dir behind when it ends: this and the
    # security example's freeze were 160 of the 220 MB each run left in tmp/.
    # The source and build.json stay, for whoever is looking into a failure.
    on_exit(fn -> File.rm_rf(Path.join(build.root, "runtime")) end)

    input = %{prompt: "guide", cwd: source, timeout_ms: 60_000}

    assert {:error, :live_confirmation_required} = Build.run(build, input)
    assert {:ok, observation} = Build.run(build, input, allow_live: true)

    assert observation["answer"] == "frozen builder ready"
    assert observation["tool_metrics"]["errors"] == 0
    assert observation["tool_metrics"]["calls"] == 1
    assert observation["frozen_build_sha256"] == build.sha256
    assert :ok = Build.verify(build)
  end
end
