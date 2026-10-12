defmodule Lemieux.MixProjectTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "the package version matches the standalone release version" do
    assert Mix.Project.config()[:version] == "VERSION" |> File.read!() |> String.trim()
  end

  test "the dependency manifest can be evaluated in isolation", %{tmp_dir: tmp_dir} do
    File.cp!("mix.exs", Path.join(tmp_dir, "mix.exs"))

    {output, status} =
      System.cmd("mix", ["help"],
        cd: tmp_dir,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "local gates enforce the same coverage check as CI in a separate VM" do
    aliases = Mix.Project.config()[:aliases]

    for gate <- [:precommit, :ci] do
      assert "cmd mix test.cover" in aliases[gate],
             "#{gate} must check the coverage suite separately from ordinary tests"
    end

    assert aliases[:"test.cover"] ==
             "test --cover --preload-modules --warnings-as-errors --raise"

    assert Lemieux.MixProject.cli()[:preferred_envs][:"test.cover"] == :test

    for workflow <- ["ci", "nightly"] do
      assert File.read!(".github/workflows/#{workflow}.yml") =~ "run: mix test.cover"
    end
  end

  test "a coverage failure stops the gate even when every test passes", %{tmp_dir: tmp_dir} do
    coverage_check = Mix.Project.config()[:aliases][:"test.cover"]
    assert is_binary(coverage_check)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule CoverageGateFixture.MixProject do
      use Mix.Project
      def project do
        [app: :coverage_gate_fixture, version: "0.1.0", deps: [],
         test_coverage: [summary: [threshold: 85]],
         aliases: [gate: ["cmd mix test.cover", &after_coverage/1],
                   "test.cover": #{inspect(coverage_check)}]]
      end
      def cli, do: [preferred_envs: [gate: :test, "test.cover": :test]]
      defp after_coverage(_args), do: File.write!("after-coverage", "ran")
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/fixture.ex"), """
    defmodule CoverageGateFixture do
      def covered, do: :ok
      def uncovered, do: :never_called
    end
    """)

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(tmp_dir, "test/fixture_test.exs"), """
    defmodule CoverageGateFixtureTest do
      use ExUnit.Case, async: true
      test "passes" do
        assert CoverageGateFixture.covered() == :ok
        File.write!("test-passed", "ran")
      end
    end
    """)

    {output, status} =
      System.cmd("mix", ["gate"], cd: tmp_dir, stderr_to_stdout: true)

    assert status != 0, output
    assert File.exists?(Path.join(tmp_dir, "test-passed")), output
    assert output =~ "Coverage test failed"
    refute File.exists?(Path.join(tmp_dir, "after-coverage"))
  end

  describe "scripts/check_lock_drift.exs" do
    test "fails naming each shared dependency the two locks resolve differently", %{
      tmp_dir: tmp_dir
    } do
      root =
        write_lock(tmp_dir, "root.lock", [
          hex("jsv", "0.23.1"),
          hex("texture", "2.0.0"),
          hex("req", "0.7.1"),
          hex("only_here", "1.0.0")
        ])

      release = write_lock(tmp_dir, "release.lock", [hex("jsv", "0.21.2"), hex("req", "0.7.1")])

      {output, status} = drift_check([root, release])

      assert status == 1, output
      assert output =~ ~r/jsv\b.*0\.23\.1.*0\.21\.2/
      refute output =~ "req"
      refute output =~ "only_here"
    end

    test "passes when every shared dependency resolves identically", %{tmp_dir: tmp_dir} do
      root = write_lock(tmp_dir, "root.lock", [hex("jsv", "0.23.1"), hex("only_here", "1.0.0")])

      release =
        write_lock(tmp_dir, "release.lock", [hex("jsv", "0.23.1"), hex("castle", "0.3.1")])

      assert {_output, 0} = drift_check([root, release])
    end

    test "tolerates only the reviewed exceptions it is given", %{tmp_dir: tmp_dir} do
      root = write_lock(tmp_dir, "root.lock", [hex("jsv", "0.23.1"), hex("req", "0.7.2")])
      release = write_lock(tmp_dir, "release.lock", [hex("jsv", "0.21.2"), hex("req", "0.7.1")])

      {output, 1} = drift_check(["--allow", "jsv", root, release])
      [notices, failures] = String.split(output, "Lockfiles disagree", parts: 2)
      assert notices =~ "Allowed drift: jsv:"
      assert failures =~ "req:"
      refute failures =~ "jsv:"

      assert {_output, 0} = drift_check(["--allow", "jsv,req", root, release])
    end

    test "says when a reviewed exception no longer drifts", %{tmp_dir: tmp_dir} do
      root = write_lock(tmp_dir, "root.lock", [hex("jsv", "0.23.1")])
      release = write_lock(tmp_dir, "release.lock", [hex("jsv", "0.23.1")])

      {output, 0} = drift_check(["--allow", "jsv", root, release])
      assert output =~ ~r/jsv.*no longer drifts/
    end
  end

  defp drift_check(args),
    do: System.cmd("elixir", ["scripts/check_lock_drift.exs" | args], stderr_to_stdout: true)

  defp hex(name, version),
    do: ~s(  "#{name}": {:hex, :#{name}, "#{version}", "0000", [:mix], [], "hexpm", "1111"},)

  defp write_lock(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, Enum.join(["%{" | entries] ++ ["}"], "\n"))
    path
  end
end
