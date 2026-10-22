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
    assert block =~ "- Source: BEAM host; tool execution may use another machine"
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

  test "origin is sanitized beside its nested working directory and frozen at startup", %{
    tmp_dir: tmp_dir
  } do
    dir = repository(tmp_dir)
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)

    git(dir, [
      "remote",
      "add",
      "origin",
      "https://user:secret@GitHub.com:443/acme/project.git?token=private#hidden"
    ])

    {:ok, state} = EnvironmentContext.init(cwd: nested, now: @now)
    git(dir, ["remote", "set-url", "origin", "git@github.com:other/replacement.git"])
    harness = EnvironmentContext.apply(Harness.new(system: "base"), state)

    assert harness.system =~
             "- Working directory: #{nested}\n- Git remote: github.com/acme/project"

    assert harness.system =~ "- Source: BEAM host; tool execution may use another machine"
    refute harness.system =~ "replacement"
    refute harness.system =~ "secret"
    refute harness.system =~ "private"
    refute harness.system =~ "hidden"
    assert block(cwd: nested) =~ "- Git remote: github.com/other/replacement"
  end

  test "absent, local and ambiguous origins keep directory and status without a remote", %{
    tmp_dir: tmp_dir
  } do
    dir = repository(tmp_dir)
    refute block(cwd: dir) =~ "- Git remote:"

    for remote <- [
          "/private/repo.git",
          "../repo.git",
          "github.com/acme/project.git",
          "gitlab/acme/project.git",
          "C:acme/project.git",
          "c:acme/project.git",
          "file:///private/repo.git",
          "ext::secret",
          "https://github.com/acme/../project.git"
        ] do
      git(dir, ["config", "remote.origin.url", remote])
      snapshot = block(cwd: dir)
      assert snapshot =~ "- Working directory: #{dir}"
      assert snapshot =~ "- Git: repository on branch main"
      refute snapshot =~ "- Git remote:"
    end

    git(dir, ["config", "remote.origin.url", "https://github.com/acme/one.git"])
    git(dir, ["config", "--add", "remote.origin.url", "https://github.com/acme/two.git"])
    refute block(cwd: dir) =~ "- Git remote:"
  end

  test "a linked worktree reads its common origin through its own nested directory", %{
    tmp_dir: tmp_dir
  } do
    dir = repository(tmp_dir)
    git(dir, ["remote", "add", "origin", "ssh://git@GitLab:2222/acme/project.git.git"])
    linked = Path.join(dir, "linked")
    git(dir, ["worktree", "add", "--detach", "--no-checkout", linked])
    nested = Path.join(linked, "nested")
    File.mkdir_p!(nested)

    snapshot = block(cwd: nested)

    assert snapshot =~ "- Working directory: #{nested}\n- Git remote: gitlab/acme/project.git"
    assert snapshot =~ "- Git: repository with a detached HEAD"
    refute snapshot =~ "ssh://"
    refute snapshot =~ ":2222"
  end

  test "origin stays local data without includes, URL rewrites or repository programs", %{
    tmp_dir: tmp_dir
  } do
    dir = repository(tmp_dir)
    marker = Path.join(dir, "executed")
    script = Path.join(dir, "monitor.sh")
    File.write!(script, "#!/bin/sh\ntouch #{LemieuxTest.Shell.quoted(marker)}\n")
    File.chmod!(script, 0o755)
    git(dir, ["config", "core.fsmonitor", script])
    git(dir, ["config", "remote.origin.url", "https://github.com/acme/project.git"])
    git(dir, ["config", "url.https://secret@elsewhere.example/.insteadOf", "https://github.com/"])
    included = Path.join(dir, "included.config")

    File.write!(
      included,
      "[remote \"origin\"]\nurl = https://secret@elsewhere.example/other/repo.git\n"
    )

    git(dir, ["config", "include.path", included])

    assert block(cwd: dir) =~ "- Git remote: github.com/acme/project"
    refute File.exists?(marker)
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
