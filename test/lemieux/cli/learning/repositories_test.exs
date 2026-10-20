defmodule Lemieux.CLI.Learning.RepositoriesTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.Repositories
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
end
