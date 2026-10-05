defmodule Lemieux.CLI.SourceUpdateTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.SourceUpdate
  alias Lemieux.CLI.UpdateCheck
  alias Lemieux.TUI
  alias Lemieux.TUI.Notices
  alias Lemieux.TUI.Updates

  setup do
    base = Path.join(System.tmp_dir!(), "lmx-update-#{System.unique_integer([:positive])}")
    remote = Path.join(base, "remote.git")
    seed = Path.join(base, "seed")
    source = Path.join(base, "source 'checkout")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    git!(base, ["init", "--bare", "--initial-branch=main", remote])
    git!(base, ["clone", remote, seed])
    configure(seed)
    File.write!(Path.join(seed, "mix.exs"), "# lemieux source\n")
    File.write!(Path.join(seed, "VERSION"), "0.1.0\n")
    commit(seed, "initial")
    git!(seed, ["push", "-u", "origin", "main"])
    git!(base, ["clone", remote, source])
    configure(source)
    %{base: base, seed: seed, source: source, opts: [source_path: source]}
  end

  test "fetches and fast-forwards the configured upstream even without a version bump", ctx do
    old = git!(ctx.source, ["rev-parse", "HEAD"])
    target = publish(ctx.seed)
    assert {:ok, info} = SourceUpdate.check(ctx.opts)
    assert info["version"] == target
    assert info["notice"] =~ "Git"
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == old
    assert {:ok, :restart} = SourceUpdate.apply(info, ctx.opts)
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == target
    assert File.read!(Path.join(ctx.source, "VERSION")) == "0.1.0\n"
    assert SourceUpdate.check(ctx.opts) == :current
  end

  test "uses the branch upstream rather than assuming origin/main", ctx do
    git!(ctx.seed, ["checkout", "-b", "updates"])
    git!(ctx.seed, ["push", "-u", "origin", "updates"])
    git!(ctx.source, ["remote", "rename", "origin", "releases"])
    git!(ctx.source, ["fetch", "releases"])
    git!(ctx.source, ["branch", "--set-upstream-to=releases/updates", "main"])
    target = publish(ctx.seed, "updates")
    assert {:ok, info} = SourceUpdate.check(ctx.opts)
    assert info["version"] == target
    assert {:ok, :restart} = SourceUpdate.apply(info, ctx.opts)
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == target
  end

  test "refuses tracked, staged and untracked changes without stashing them", ctx do
    publish(ctx.seed)

    for change <- [:tracked, :staged, :untracked] do
      path = Path.join(ctx.source, if(change == :untracked, do: "draft", else: "VERSION"))
      File.write!(path, "local work\n")
      if change == :staged, do: git!(ctx.source, ["add", "VERSION"])
      assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :dirty}}
      assert File.read!(path) == "local work\n"
      File.rm!(path)
      git!(ctx.source, ["reset", "--hard", "HEAD"])
    end
  end

  test "refuses detached branches and branches without an upstream", ctx do
    git!(ctx.source, ["branch", "--unset-upstream"])
    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :no_upstream}}
    git!(ctx.source, ["checkout", "--detach"])
    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :detached}}
  end

  test "refuses ahead and diverged histories without creating a merge commit", ctx do
    File.write!(Path.join(ctx.source, "local"), "local work")
    commit(ctx.source, "local commit")
    head = git!(ctx.source, ["rev-parse", "HEAD"])
    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :not_fast_forward}}
    publish(ctx.seed)
    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :not_fast_forward}}
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == head
  end

  test "rechecks local changes and HEAD before applying a staged update", ctx do
    publish(ctx.seed)
    assert {:ok, info} = SourceUpdate.check(ctx.opts)
    File.write!(Path.join(ctx.source, "draft"), "keep this")
    assert SourceUpdate.apply(info, ctx.opts) == {:error, {:source_update, :dirty}}
    assert File.read!(Path.join(ctx.source, "draft")) == "keep this"
    commit(ctx.source, "work after fetch")
    assert SourceUpdate.apply(info, ctx.opts) == {:error, {:source_update, :checkout_changed}}
  end

  test "rechecks the branch and upstream even when HEAD has not moved", ctx do
    publish(ctx.seed)
    assert {:ok, info} = SourceUpdate.check(ctx.opts)
    git!(ctx.source, ["checkout", "-b", "other"])
    git!(ctx.source, ["branch", "--set-upstream-to=origin/main", "other"])
    assert SourceUpdate.apply(info, ctx.opts) == {:error, {:source_update, :checkout_changed}}
    git!(ctx.source, ["checkout", "main"])
    git!(ctx.source, ["branch", "--unset-upstream"])
    assert SourceUpdate.apply(info, ctx.opts) == {:error, {:source_update, :no_upstream}}
  end

  test "refuses another repository root and an in-progress Git operation", ctx do
    nested = Path.join(ctx.source, "nested")
    File.mkdir_p!(nested)
    assert SourceUpdate.check(source_path: nested) == {:error, {:source_update, :not_checkout}}
    assert SourceUpdate.check(source_path: ctx.base) == {:error, {:source_update, :not_checkout}}
    File.write!(Path.join(ctx.source, ".git/MERGE_HEAD"), git!(ctx.source, ["rev-parse", "HEAD"]))
    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :git_busy}}
  end

  test "failed fetches leave the checkout unchanged and do not expose remote details", ctx do
    head = git!(ctx.source, ["rev-parse", "HEAD"])

    git!(ctx.source, [
      "remote",
      "set-url",
      "origin",
      Path.join(ctx.base, "missing-private-remote")
    ])

    assert SourceUpdate.check(ctx.opts) == {:error, {:source_update, :fetch_failed}}
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == head
  end

  test "explicit /update bypasses Hex availability and works with automatic checks disabled",
       ctx do
    tasks = start_supervised!(Task.Supervisor)
    target = publish(ctx.seed)

    host =
      UpdateCheck.host(tasks,
        source_path: ctx.source,
        cwd: ctx.seed,
        check_updates: false,
        get: fn _, _ -> flunk("explicit Git updates must not depend on Hex") end
      )

    state = TUI.new(test_mode: {80, 24}, id: "source-update", model: "test:model", updates: host)
    state = put_in(state.status.update.phase, :available)
    state = put_in(state.status.update.pending, %{"version" => "999.0.0"})
    checking = Updates.request(state)
    assert checking.status.update.phase == :check
    assert newest_notice(checking) == "Checking the source checkout's Git upstream…"
    staged = finish_task(checking) |> finish_task()
    assert staged.status.update.phase == :apply
    updated = finish_task(staged)
    assert updated.status.update.phase == :restart
    assert updated.status.update.installed == target
    notice = newest_notice(updated)
    assert notice =~ String.slice(target, 0, 12)
    assert notice =~ "mix deps.get"
    assert notice =~ "restart mix lmx to load it"
    assert git!(ctx.seed, ["rev-parse", "HEAD"]) == target
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == target
    restarted = Updates.start(Notices.dismiss(updated))
    assert newest_notice(restarted) == notice
    assert restarted.status.update.timer == nil
    refute_receive :check_update
  end

  test "source update failures surface useful Git guidance in the TUI", ctx do
    tasks = start_supervised!(Task.Supervisor)
    File.write!(Path.join(ctx.source, "draft"), "keep my draft")
    host = UpdateCheck.host(tasks, ctx.opts)
    state = TUI.new(test_mode: {80, 24}, id: "source-dirty", model: "test:model", updates: host)
    checked = state |> Updates.request() |> finish_task()
    assert checked.status.update.phase == :idle
    notice = newest_notice(checked)
    assert notice =~ "local changes"
    assert notice =~ "Commit or stash"
    assert File.read!(Path.join(ctx.source, "draft")) == "keep my draft"
  end

  test "an ignored file is not overwritten by an incoming tracked file", ctx do
    File.write!(Path.join(ctx.source, ".git/info/exclude"), "upstream\n")
    File.write!(Path.join(ctx.source, "upstream"), "ignored local work")
    publish(ctx.seed)
    assert {:ok, info} = SourceUpdate.check(ctx.opts)
    assert SourceUpdate.apply(info, ctx.opts) == {:error, {:source_update, :apply_failed}}
    assert File.read!(Path.join(ctx.source, "upstream")) == "ignored local work"
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == info["head"]
  end

  test "linked worktrees update their own branch", ctx do
    worktree = Path.join(ctx.base, "linked")
    git!(ctx.source, ["worktree", "add", "-b", "linked", worktree])
    git!(worktree, ["branch", "--set-upstream-to=origin/main", "linked"])
    target = publish(ctx.seed)
    assert {:ok, info} = SourceUpdate.check(source_path: worktree)
    assert {:ok, :restart} = SourceUpdate.apply(info, source_path: worktree)
    assert git!(worktree, ["rev-parse", "HEAD"]) == target
    assert git!(ctx.source, ["rev-parse", "HEAD"]) == info["head"]
  end

  test "a silent Git fetch is bounded and leaves HEAD unchanged", ctx do
    script = Path.join(ctx.base, "slow-upload-pack")
    File.write!(script, "#!/bin/sh\nexec sleep 3\n")
    File.chmod!(script, 0o700)
    git!(ctx.source, ["config", "remote.origin.uploadpack", script])
    head = git!(ctx.source, ["rev-parse", "HEAD"])

    assert SourceUpdate.check(ctx.opts ++ [timeout_ms: 1_000]) ==
             {:error, {:source_update, :fetch_failed}}

    assert git!(ctx.source, ["rev-parse", "HEAD"]) == head
  end

  defp finish_task(state) do
    ref = state.status.update.task.ref
    assert_receive {^ref, result}, 5_000
    {:noreply, state} = TUI.handle_info({ref, result}, state)
    state
  end

  # Update notices go to the notice box; the newest is what the step said.
  defp newest_notice(state), do: state |> Notices.items() |> List.last() |> Map.fetch!(:text)

  defp publish(seed, branch \\ "main") do
    File.write!(Path.join(seed, "upstream"), "new code")
    commit(seed, "upstream commit")
    git!(seed, ["push", "origin", branch])
    git!(seed, ["rev-parse", "HEAD"])
  end

  defp configure(path) do
    git!(path, ["config", "user.name", "Update test"])
    git!(path, ["config", "user.email", "update@example.invalid"])
    git!(path, ["config", "commit.gpgsign", "false"])
    git!(path, ["config", "core.hooksPath", "/dev/null"])
  end

  defp commit(path, message) do
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", message])
  end

  defp git!(path, args) do
    {output, status} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
