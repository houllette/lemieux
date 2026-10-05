defmodule Lemieux.CLI.SavedPluginsTest do
  @moduledoc """
  A plugin saved with `lmx plugin install` is a standing choice, not a flag.
  Counting it as one made `lmx explain`, `--bare`, `--system`, `--resume` and
  `--continue` fail, for anyone who had installed a plugin, with an error
  about flags they never passed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "plugins/review-kit")

    write(
      plugin,
      "skills/review/SKILL.md",
      "---\nname: review\ndescription: Review a change when asked.\n---\nLook closely."
    )

    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project, ".git"))
    File.write!(Path.join(project, "AGENTS.md"), "Project rule.")

    config = Path.join(tmp_dir, "lmx/config.json")
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, JSON.encode!(%{"version" => 1, "plugin_dirs" => [plugin]}))
    File.chmod!(config, 0o600)

    personal = Path.join(tmp_dir, "personal")

    %{
      config: config,
      project: project,
      store: JSONL.new(Path.join(tmp_dir, "sessions")),
      supervisor: :"lemieux_saved_plugins_test_#{System.unique_integer([:positive])}",
      personal: [
        personal_dir: personal,
        claude_personal_dir: Path.join(personal, "claude"),
        codex_personal_dir: Path.join(personal, "codex"),
        agents_personal_dir: Path.join(personal, "agents")
      ]
    }
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp lmx(argv, ctx, provider) do
    opts =
      [
        provider: provider,
        store: ctx.store,
        supervisor: ctx.supervisor,
        cwd: ctx.project,
        stdin_terminal?: true
      ] ++ ctx.personal

    stdout =
      capture_io(fn ->
        capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
        |> then(&send(self(), {:stderr, &1}))
      end)

    assert_received {:status, status}
    assert_received {:stderr, stderr}
    %{status: status, stdout: stdout, stderr: stderr}
  end

  test "explain starts from the workspace a run would, saved plugins included", ctx do
    result = lmx(["explain", "--config", ctx.config], ctx, Scripted.new([]))

    assert result.status == :ok, result.stderr
    report = JSON.decode!(result.stdout)

    assert Enum.any?(report["extensions"], &(&1["module"] == "Lemieux.Extensions.Workspace"))
    # The plugin's skill is offered through the skill loader.
    assert "skill" in Enum.map(report["tools"], & &1["name"])
  end

  test "a --bare run starts, and says which saved plugins it left out", ctx do
    provider = Scripted.new([[{:text_delta, "ok"}, {:done, :stop}]])
    result = lmx(["run", "--bare", "--config", ctx.config, "hi"], ctx, provider)

    assert result.status == :ok, result.stderr
    assert result.stdout == "ok\n"

    assert result.stderr =~
             "saved plugins are not loaded in a --bare run, so their hooks and MCP servers " <>
               "are off for it: review-kit"
  end

  test "--system leaves the workspace out the same way", ctx do
    provider = Scripted.new([[{:done, :stop}]])
    result = lmx(["run", "--system", "be terse", "--config", ctx.config, "hi"], ctx, provider)

    assert result.status == :ok, result.stderr
    assert result.stderr =~ "not loaded in a --system run"
    assert [%{system: system}] = Scripted.requests(provider)
    assert system =~ "be terse"
    refute system =~ "review-kit"
    refute system =~ "Project rule."
  end

  test "a resumed session gets the workspace it started with, and its plugins", ctx do
    first = Scripted.new([[{:done, :stop}]])
    assert lmx(["run", "--config", ctx.config, "first"], ctx, first).status == :ok
    assert [%{system: started}] = Scripted.requests(first)
    assert started =~ "review-kit:review"

    assert {:ok, [session]} = Store.list_sessions(ctx.store)

    resumed = Scripted.new([[{:done, :stop}]])
    result = lmx(["run", "--resume", session, "--config", ctx.config, "again"], ctx, resumed)
    assert result.status == :ok, result.stderr

    assert [%{system: system}] = Scripted.requests(resumed)
    assert system =~ "review-kit:review"
    assert system =~ "Project rule."
    # Replaced, not stacked on the layer the transcript recorded.
    assert length(String.split(system, "<!-- lmx-workspace-context:start -->")) == 2

    continued = Scripted.new([[{:done, :stop}]])
    assert lmx(["run", "-c", "--config", ctx.config, "third"], ctx, continued).status == :ok
    assert [%{system: system}] = Scripted.requests(continued)
    assert system =~ "review-kit:review"
  end

  test "a resumed session that started bare stays bare", ctx do
    first = Scripted.new([[{:done, :stop}]])
    lmx(["run", "--bare", "--config", ctx.config, "first"], ctx, first)
    assert [%{system: started}] = Scripted.requests(first)
    refute started =~ "Project rule."

    assert {:ok, [session]} = Store.list_sessions(ctx.store)
    resumed = Scripted.new([[{:done, :stop}]])
    result = lmx(["run", "--resume", session, "--config", ctx.config, "again"], ctx, resumed)

    assert result.status == :ok, result.stderr
    assert [%{system: ^started}] = Scripted.requests(resumed)
  end

  test "a plugin typed on a bare command line is still refused", ctx do
    result =
      lmx(
        ["run", "--bare", "--plugin-dir", Path.join(ctx.project, "x"), "hi"],
        ctx,
        Scripted.new([])
      )

    assert result.status == {:error, 2}
    assert result.stderr =~ "full TUI workspace experience"
  end
end
