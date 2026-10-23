defmodule Lemieux.CLI.Learning.RepositoriesTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.Repositories
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  @moduletag :tmp_dir

  defmodule Counts do
    @behaviour Lemieux.Environment
    @impl true
    def read_file(_, _, _), do: {:error, :unused}
    @impl true
    def write_file(_, _, _, _), do: {:error, :unused}
    @impl true
    def run(counts, _command, _opts),
      do: {:ok, [{:data, "QUALIFICATION_COUNTS=" <> JSON.encode!(counts)}, {:exit_status, 0}]}
  end

  defmodule PythonEnvironment do
    @behaviour Lemieux.Environment
    @impl true
    def read_file(_, cwd, path), do: Local.read_file(nil, cwd, path)
    @impl true
    def write_file(_, cwd, path, bytes), do: Local.write_file(nil, cwd, path, bytes)
    @impl true
    def run({python, report}, command, opts) do
      command =
        command
        |> String.replace("python3", Sandbox.quote_shell(python))
        |> String.replace("/tmp/qualification.xml", report)

      Local.run(nil, command, opts)
    end
  end

  test "workspace modules cannot impersonate pytest or the trusted count parser", ctx do
    # A tiny installed verifier fixture avoids a pip/network dependency. Its
    # two checks are distinguishable from the workspace's forged 999 checks.
    sandbox = Path.join(System.tmp_dir!(), "lmx-grader-" <> Lemieux.ID.generate())
    File.mkdir_p!(sandbox)
    on_exit(fn -> File.rm_rf(sandbox) end)
    venv = Path.join(sandbox, "venv")

    assert {_, 0} =
             System.cmd("python3", ["-m", "venv", "--without-pip", venv], stderr_to_stdout: true)

    python = Path.join(venv, "bin/python3")

    assert {site, 0} =
             System.cmd(python, [
               "-I",
               "-c",
               "import sysconfig; print(sysconfig.get_paths()['purelib'])"
             ])

    File.write!(Path.join(String.trim(site), "pytest.py"), """
    from pathlib import Path
    def main(args):
        path = next(x.split('=', 1)[1] for x in args if x.startswith('--junitxml='))
        Path(path).write_text('<testsuites><testsuite tests="2" failures="0" errors="0" skipped="0"/></testsuites>')
        return 0
    """)

    report = Path.join(sandbox, "counts.xml")

    File.write!(Path.join(ctx.cwd, "pytest.py"), """
    from pathlib import Path
    Path('shadow-executed').write_text('workspace pytest ran')
    Path(#{inspect(report)}).write_text('<testsuites><testsuite tests="999" failures="0" errors="0" skipped="0"/></testsuites>')
    """)

    File.write!(Path.join(ctx.cwd, "json.py"), """
    from pathlib import Path
    Path('shadow-executed').write_text('workspace parser ran')
    def dumps(value):
        return '{"tests":999,"failures":0,"errors":0,"skipped":0,"status":0}'
    """)

    fixture = %{ctx.fixture | cases: ctx.fixture.probe_cases}
    result = Repositories.grade(fixture, ctx.cwd, {PythonEnvironment, {python, report}})
    assert result["checks"] == 2
    assert result["passed"]
    refute File.exists?(Path.join(ctx.cwd, "shadow-executed"))
  end

  setup %{tmp_dir: dir} do
    private = Path.join(dir, "private")
    File.mkdir_p!(private)
    File.write!(Path.join(private, "test_private.py"), "private test bytes")
    {:ok, digest} = Leases.source_digest(private)
    File.write!(Path.join(dir, "test_public.py"), "immutable")

    public =
      {Counts, %{"tests" => 10, "failures" => 0, "errors" => 0, "skipped" => 0, "status" => 0}}

    grader =
      {Counts, %{"tests" => 4, "failures" => 1, "errors" => 0, "skipped" => 0, "status" => 1}}

    fixture = %{
      cases: [{digest, true}],
      probe_cases: [{"public", true}],
      private_tests: private,
      private_tests_sha256: digest,
      grader_environment: grader,
      public_pytest_args: ["test_public.py"],
      immutable: %{"test_public.py" => "immutable"}
    }

    %{fixture: fixture, public: public, cwd: dir}
  end

  test "public feedback can pass while private confirmation fails without changing the selection signal",
       ctx do
    public =
      Repositories.grade(%{ctx.fixture | cases: ctx.fixture.probe_cases}, ctx.cwd, ctx.public)

    private = Repositories.grade(ctx.fixture, ctx.cwd, ctx.public)
    assert public["passed"]
    refute private["passed"]
    assert private["correct"] == 3
    assert private["score"] == 0.75
  end

  test "a nonzero pytest status and an immutable-test edit cannot be hidden by passing counts",
       ctx do
    {Counts, counts} = ctx.public
    environment = {Counts, Map.put(counts, "status", 1)}
    fixture = %{ctx.fixture | cases: ctx.fixture.probe_cases}
    refute Repositories.grade(fixture, ctx.cwd, environment)["passed"]
    File.write!(Path.join(ctx.cwd, "test_public.py"), "changed")

    assert Repositories.grade(fixture, ctx.cwd, ctx.public)["safety_failures"] == [
             "modified_test_public.py"
           ]
  end

  test "changed private material refuses grading", ctx do
    File.write!(Path.join(ctx.fixture.private_tests, "test_private.py"), "changed")
    assert_raise MatchError, fn -> Repositories.grade(ctx.fixture, ctx.cwd, ctx.public) end
  end

  test "skipping a frozen required check cannot turn the remaining passes into success", ctx do
    {Counts, counts} = ctx.public

    fixture =
      ctx.fixture
      |> Map.put(:cases, ctx.fixture.probe_cases)
      |> Map.put(:minimum_checks, %{"public" => 10, "private" => 4})

    skipped = {Counts, Map.put(counts, "skipped", 1)}
    result = Repositories.grade(fixture, ctx.cwd, skipped)
    assert result["correct"] == 9
    refute result["passed"]
    refute result["verification_complete"]
    assert Repositories.grade(fixture, ctx.cwd, ctx.public)["passed"]
  end

  test "a compact disclosure resolves the exact frozen verification list and refuses tampering",
       ctx do
    paths = ["contract.json", "test_public.py"]
    contract = Path.join(ctx.cwd, "contract.json")
    File.write!(contract, JSON.encode!(%{"schema_version" => 1, "paths" => paths}))
    assert {:ok, notice} = Repositories.verification_notice(ctx.cwd, paths, "contract.json")
    assert notice =~ "Read contract.json"
    assert byte_size(notice) < 256
    refute notice =~ "test_public.py"

    File.write!(contract, JSON.encode!(%{"schema_version" => 1, "paths" => ["contract.json"]}))

    assert {:error, :verification_contract_unavailable_or_mismatched} =
             Repositories.verification_notice(ctx.cwd, paths, "contract.json")

    File.rm!(contract)
    File.ln_s!(Path.join(ctx.cwd, "test_public.py"), contract)

    assert {:error, :verification_contract_unavailable_or_mismatched} =
             Repositories.verification_notice(ctx.cwd, paths, "contract.json")
  end

  test "verification contracts reject escaped paths, duplicate entries and oversized metadata",
       ctx do
    for paths <- [["../outside"], ["/outside"], ["test_public.py", "test_public.py"]] do
      assert {:error, :invalid_verification_paths} =
               Repositories.verification_notice(ctx.cwd, paths, nil)
    end

    File.write!(Path.join(ctx.cwd, "contract.json"), String.duplicate("x", 65_537))

    assert {:error, :verification_contract_unavailable_or_mismatched} =
             Repositories.verification_notice(ctx.cwd, ["contract.json"], "contract.json")

    assert {:ok, "- test_public.py"} =
             Repositories.verification_notice(ctx.cwd, ["test_public.py"], nil)
  end
end
