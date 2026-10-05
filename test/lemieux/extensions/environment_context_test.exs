defmodule Lemieux.Extensions.EnvironmentContextTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions
  alias Lemieux.Extensions.EnvironmentContext
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir
  @now ~N[2026-09-28 14:00:00]

  defp git(dir, args) do
    {_output, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@example.com" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    :ok
  end

  defp repository(dir) do
    git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "committed.txt"), "one\n")
    git(dir, ["add", "committed.txt"])
    git(dir, ["commit", "-q", "-m", "first"])
    dir
  end

  defp block(opts) do
    {:ok, state} = EnvironmentContext.init([now: @now] ++ opts)
    state.block
  end

  test "names the date, platform, directory and the tree's state at start", %{tmp_dir: tmp_dir} do
    dir = repository(tmp_dir)
    File.write!(Path.join(dir, "committed.txt"), "two\n")
    File.write!(Path.join(dir, "new.txt"), "fresh\n")

    block = block(cwd: dir)

    assert block =~ "## Environment"
    assert block =~ "- Date: 2026-09-28 (when this session started)"
    assert block =~ "- Platform: "
    assert block =~ "- Working directory: #{dir}"
    assert block =~ "- Git: repository on branch main"
    assert block =~ "uncommitted changes when the session started"
    assert block =~ " M committed.txt"
    assert block =~ "?? new.txt"
  end

  test "a clean repository says so", %{tmp_dir: tmp_dir} do
    assert block(cwd: repository(tmp_dir)) =~
             "on branch main; no uncommitted changes when the session started"
  end

  test "a directory outside git says that instead" do
    outside =
      System.tmp_dir!() |> Path.join("lmx-env-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert block(cwd: outside) =~ "- Git: not a repository"
  end

  test "the status is capped", %{tmp_dir: tmp_dir} do
    dir = repository(tmp_dir)
    for n <- 1..25, do: File.write!(Path.join(dir, "file#{n}.txt"), "x")

    block = block(cwd: dir)
    assert block =~ "… and 5 more"
    assert length(Regex.scan(~r/^    \?\? /m, block)) == 20
  end

  test "reading git takes no lock a person's own git command would trip over", %{
    tmp_dir: tmp_dir
  } do
    dir = repository(tmp_dir)
    File.write!(Path.join(dir, "committed.txt"), "changed\n")
    index = Path.join([dir, ".git", "index"])
    before = File.stat!(index).mtime

    _block = block(cwd: dir)

    refute File.exists?(Path.join([dir, ".git", "index.lock"]))
    assert File.stat!(index).mtime == before
  end

  describe "apply/2" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, state} = EnvironmentContext.init(cwd: tmp_dir, now: @now)
      %{state: state}
    end

    test "appends the block after the prompt, between markers", %{state: state} do
      harness = EnvironmentContext.apply(Harness.new(system: "base prompt"), state)

      assert String.starts_with?(harness.system, "base prompt\n\n<!-- lmx-environment:start -->")
      assert harness.system =~ state.block
      assert String.ends_with?(harness.system, "<!-- lmx-environment:end -->")
    end

    test "composing twice replaces the block rather than stacking it", %{state: state} do
      once = EnvironmentContext.apply(Harness.new(system: "base"), state)
      twice = EnvironmentContext.apply(once, state)

      assert twice.system == once.system
    end

    test "a later block replaces an earlier one, keeping what came after it", %{state: state} do
      stale = EnvironmentContext.compose("base", "## Environment\n\n- Date: 2020-01-01")
      composed = EnvironmentContext.compose(stale <> "\n\nhost suffix", state.block)

      refute composed =~ "2020-01-01"
      assert composed =~ "host suffix"
      assert composed =~ "2026-09-28"
    end

    test "a host that disabled the prompt keeps it disabled", %{state: state} do
      assert EnvironmentContext.apply(Harness.new(system: nil), state).system == nil
    end
  end

  test "the coding recipe offers it by name and leaves it off by default", %{tmp_dir: tmp_dir} do
    provider = Scripted.new([])

    refute Keyword.has_key?(Extensions.coding("test:model", provider), :environment_context)

    recipe =
      Extensions.coding("test:model", provider,
        environment_context: true,
        delegate: false,
        cwd: tmp_dir
      )

    assert [environment_context: {EnvironmentContext, [cwd: ^tmp_dir]}] = recipe
    assert {:ok, harness} = Harness.assemble(Harness.new(), Keyword.values(recipe))
    assert harness.system =~ "- Working directory: #{tmp_dir}"
  end
end
