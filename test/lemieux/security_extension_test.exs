for path <- Path.wildcard(Path.expand("../../examples/extensions/security/lib/**/*.ex", __DIR__)) do
  Code.require_file(path)
end

defmodule Lemieux.SecurityExtensionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Tool
  alias SecurityExample.Tools.Nmap

  @moduletag :tmp_dir

  defmodule Environment do
    def run(owner, command, opts) do
      send(owner, {:command, command, opts})
      {:ok, [{:data, "<nmaprun></nmaprun>"}, {:exit_status, 2}]}
    end
  end

  test "native wrapper uses host execution and preserves command failure facts" do
    context = %{cwd: "/workspace", environment: {Environment, self()}}
    assert :ok = Tool.validate_all(SecurityExample.tool_registry())

    assert {:ok, result} =
             Nmap.run(
               %{"target" => "192.0.2.1", "ports" => [443, 80]},
               context
             )
             |> Tool.collect_result(fn _chunk -> :ok end, 30_000)

    assert_receive {:command, "nmap -sT -n --host-timeout 20s -p 80,443 -oX - 192.0.2.1", opts}
    assert opts[:cwd] == "/workspace"
    assert opts[:timeout_ms] == 30_000
    assert result.structured_content == %{"status" => "exited", "exit_status" => 2}

    assert {:error, _} =
             Nmap.run(
               %{"target" => "192.0.2.1;touch bad", "ports" => [80]},
               context
             )

    refute_receive {:command, _, _}
  end

  # Freezing copies the whole runtime and the run boots it: under four seconds
  # alone on a quiet machine (2026-10-04), sixteen on a cold one, and past the
  # suite's sixty-second timeout in more than one loaded run (2026-10-01).
  # The same allowance as `Lemieux.ExtensionFrozenBuildTest`, which does the
  # same.
  @tag timeout: :timer.minutes(3)
  test "export and frozen consumer retain native tools, pipeline code and declared dependency bytes",
       %{tmp_dir: root} do
    source = Path.expand("../../examples/extensions/security", __DIR__)
    copy = Path.join(root, "source")
    assert {:ok, receipt} = Export.export(source, copy)
    assert Map.has_key?(receipt["files"], "lib/security_example/tools/nmap.ex")
    assert Map.has_key?(receipt["files"], "lib/security_example/pipeline.ex")
    assert Map.has_key?(receipt["files"], "test/pipeline_test.exs")

    # Explicit fixture injection exercises the real consumer/loop without making
    # a network scan or a provider call. Jason is an existing dependency in the
    # test runtime; this fixture proves a declared library survives freezing.
    tool_path = Path.join(copy, "lib/security_example/tools/assess_ports.ex")
    File.write!(tool_path, String.replace(File.read!(tool_path), "JSON.encode!", "Jason.encode!"))
    mix_path = Path.join(copy, "mix.exs")

    File.write!(
      mix_path,
      String.replace(File.read!(mix_path), "deps: [", "deps: [{:jason, \"~> 1.4\"}, ")
    )

    lock = File.read!(Path.expand("../../mix.lock", __DIR__))
    File.write!(Path.join(copy, "mix.lock"), lock)
    manifest_path = Path.join(copy, "lemieux-extension.json")
    manifest = manifest_path |> File.read!() |> JSON.decode!()
    File.write!(manifest_path, JSON.encode!(Map.update!(manifest, "files", &["mix.lock" | &1])))

    file = Path.join(copy, "lib/security_example.ex")

    File.write!(
      file,
      String.replace(File.read!(file), "def configure(profile), do: configure(profile, [])", """
      def configure(profile) do
        provider = Lemieux.Providers.Scripted.new([
          Lemieux.Providers.Scripted.tool_call("assess", "assess_ports", %{"ports" => [443, 23]}),
          fn request ->
            result = Enum.find(request.entries, &(&1.type == :tool_result))
            Lemieux.Providers.Scripted.complete(result.payload["output"])
          end
        ])
        configure(profile, provider: provider)
      end
      """)
    )

    profile = SecurityExample.profile("test:model") |> Profile.quota(3)
    assert {:ok, build} = Build.freeze(copy, Path.join(root, "frozen"), profile)

    # About 80 MB of copied dependency beams, which ExUnit would leave in tmp/
    # until the next run; see `Lemieux.ExtensionFrozenBuildTest`.
    on_exit(fn -> File.rm_rf(Path.join(build.root, "runtime")) end)

    assert {:ok, observation} =
             Build.run(build, %{prompt: "assess", cwd: root, timeout_ms: 15_000},
               allow_live: true
             )

    assert [%{"port" => 23}] = JSON.decode!(observation["answer"])
    assert observation["tool_metrics"]["calls"] == 1
    assert observation["tool_metrics"]["errors"] == 0
    assert File.exists?(Path.join(build.root, "runtime/jason/ebin/Elixir.Jason.beam"))
    assert File.read!(Path.join(build.root, "source/mix.lock")) == lock
  end
end
