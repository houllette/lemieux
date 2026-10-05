defmodule Lemieux.CLI.SkillsTest do
  @moduledoc """
  `lmx skills`, and the skill options every session's discovery gets
  (`Lemieux.CLI.Skills.discovery_options/2`), against a temporary home
  directory and a temporary Omarchy install: nothing here reads the real
  `~/.claude`, `~/.codex`, `~/.agents` or `/usr/share/omarchy`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Workspace.Containment

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    omarchy = Path.join(tmp_dir, "omarchy")
    system = Path.join(omarchy, "default/agents/skills")
    repo = Path.join(tmp_dir, "repo")
    extra = Path.join(tmp_dir, "extra")

    skill(system, "omarchy", "Customize the desktop.")
    write(Path.join(system, "omarchy"), "hyprland.md", "Hyprland.")
    skill(system, "diagnose-crash", "Diagnose a crash.")
    link(Path.join(system, "omarchy"), Path.join(home, ".claude/skills/omarchy"))
    link(Path.join(system, "omarchy"), Path.join(home, ".codex/skills/omarchy"))
    skill(Path.join(home, ".lmx/skills"), "notes", "My notes.")
    File.mkdir_p!(Path.join(repo, ".git"))
    skill(Path.join(repo, ".claude/skills"), "review", "Review a change.")

    skill(extra, "manual", "Run by hand.", "disable-model-invocation: true\n")

    %{
      home: home,
      system: system,
      repo: repo,
      extra: extra,
      config: config(home, %{"skills" => %{"disabled" => ["diagnose-crash", "ghost"]}}),
      opts: [
        home: home,
        personal_dir: Path.join(home, ".lmx"),
        claude_personal_dir: Path.join(home, ".claude"),
        codex_personal_dir: Path.join(home, ".codex"),
        agents_personal_dir: Path.join(home, ".agents"),
        system_skills: [
          env: %{"OMARCHY_PATH" => omarchy},
          home: home,
          packaged: Path.join(tmp_dir, "no-packaged-omarchy")
        ]
      ]
    }
  end

  test "lists every skill, where it came from, its state, and what it hid", ctx do
    %{status: :ok, stdout: out} =
      lmx(["skills", "--config", ctx.config, "--skill-dir", ctx.extra], ctx)

    real = Containment.real_path(Path.join(ctx.system, "omarchy/SKILL.md"))

    assert out =~ "Skills for a session in #{ctx.repo}:"

    assert out =~
             """
             omarchy · enabled · personal ~/.claude/skills
               ~/.claude/skills/omarchy/SKILL.md
               real path #{real}
               also at ~/.codex/skills/omarchy/SKILL.md (same file)
               also at #{Path.join(ctx.system, "omarchy/SKILL.md")} (same file)
             """

    assert out =~
             "diagnose-crash · disabled in config · omarchy\n" <>
               "  #{Path.join(ctx.system, "diagnose-crash/SKILL.md")}\n"

    # Nothing between the repository's skill and the root it was found under
    # is a link, so there is no real path to show.
    assert out =~
             "review · enabled · repository .claude/skills\n" <>
               "  .claude/skills/review/SKILL.md\n\nOmarchy skills:"

    assert out =~ "notes · enabled · personal ~/.lmx/skills\n"
    assert out =~ "manual · user-only (disable-model-invocation) · --skill-dir #{ctx.extra}\n"
    assert out =~ "create-extension · enabled · bundled\n"
    assert out =~ "Omarchy skills: on, read from #{ctx.system}."
    assert out =~ "Disabled in the config but not found: ghost."
  end

  test "--json says the same for scripts", ctx do
    %{status: :ok, stdout: out} = lmx(["skills", "--json", "--config", ctx.config], ctx)
    report = JSON.decode!(out)
    skills = Map.new(report["skills"], &{&1["name"], &1})

    assert %{
             "state" => "enabled",
             "source" => "personal",
             "kind" => "skill",
             "path" => path,
             "shadowed" => [codex, system]
           } = skills["omarchy"]

    assert path == Path.join(ctx.home, ".claude/skills/omarchy/SKILL.md")
    assert %{"source" => "personal", "same_file" => true} = codex
    assert %{"source" => "system", "from" => "omarchy", "same_file" => true} = system

    assert %{"state" => "disabled", "source" => "system", "from" => "omarchy"} =
             skills["diagnose-crash"]

    assert report["disabled"] == ["diagnose-crash", "ghost"]
    assert report["disabled_not_found"] == ["ghost"]
    assert report["personal"] == true
    assert report["system_skill_dirs"] == [ctx.system]
    assert report["omarchy"]["enabled"] == true
    assert report["omarchy"]["found"] == ctx.system
    assert report["root"] == ctx.repo
  end

  test "\"omarchy\": false stops reading Omarchy's directory, not your links to it", ctx do
    config = config(ctx.home, %{"skills" => %{"omarchy" => false}})
    %{status: :ok, stdout: out} = lmx(["skills", "--config", config], ctx)

    refute out =~ "diagnose-crash"
    assert out =~ "omarchy · enabled · personal ~/.claude/skills"
    refute out =~ "#{ctx.system}/omarchy/SKILL.md (same file)"
    assert out =~ ~s|Omarchy skills: off ("skills": {"omarchy": false} in the config).|
  end

  test "--config none reads no personal or Omarchy skills", ctx do
    %{status: :ok, stdout: out} = lmx(["skills", "--config", "none"], ctx)

    refute out =~ "omarchy ·"
    refute out =~ "notes ·"
    assert out =~ "review · enabled"
    assert out =~ "Personal and Omarchy skills: not read without a state directory"
  end

  test "-C chooses the repository, as for lmx run", ctx do
    elsewhere = Path.join(Path.dirname(ctx.repo), "other")
    File.mkdir_p!(Path.join(elsewhere, ".git"))
    skill(Path.join(elsewhere, ".agents/skills"), "other-review", "Review elsewhere.")

    %{status: :ok, stdout: out} =
      lmx(["-C", elsewhere, "skills", "--config", ctx.config], Keyword.delete(ctx.opts, :cwd))

    assert out =~ "other-review · enabled · repository .agents/skills"
    refute out =~ "review · enabled · repository .claude/skills"
  end

  test "a word or a flag it does not take is a usage error, and --help is the topic", ctx do
    assert %{status: {:error, 1}, stderr: stderr} = lmx(["skills", "list"], ctx)
    assert stderr =~ "unexpected argument list"
    assert stderr =~ "usage: lmx skills"

    assert %{status: {:error, 1}, stderr: stderr} = lmx(["skills", "--model", "x"], ctx)
    assert stderr =~ "unrecognised option --model"

    assert %{status: {:error, 1}, stderr: stderr} = lmx(["skills", "--skill-dir"], ctx)
    assert stderr =~ "missing value for --skill-dir"

    assert %{status: :ok, stdout: help} = lmx(["skills", "--help"], ctx)
    assert help =~ "Usage: lmx skills [--json]"
    assert help =~ "< ~/.lmx/skills <"
  end

  test "lmx run and the terminal UI discover the same skills through the runtime", ctx do
    {:ok, options} = Options.parse(["--config", ctx.config])
    opts = [cwd: ctx.repo] ++ ctx.opts

    assert {:ok, workspace} = Runtime.discover_workspace(options, opts)
    assert "omarchy" in Enum.map(workspace.skills, & &1.name)
    assert ["diagnose-crash"] == Enum.map(workspace.disabled_skills, & &1.name)

    # `lmx run --config none` composes over no personal or system files.
    {:ok, hermetic} = Options.parse(["--config", "none"])
    assert {:ok, run_opts} = Runtime.with_workspace(hermetic, opts)
    names = Enum.map(run_opts[:workspace].skills, & &1.name)
    assert "review" in names
    refute "omarchy" in names
    refute "diagnose-crash" in names

    # Nor does the terminal UI, which calls `discover_workspace/2` directly.
    assert {:ok, screen} = Runtime.discover_workspace(hermetic, opts)
    assert Enum.map(screen.skills, & &1.name) -- names == []
  end

  defp lmx(argv, %{opts: opts} = ctx), do: lmx(argv, Keyword.put(opts, :cwd, ctx.repo))

  defp lmx(argv, opts) when is_list(opts) do
    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
        send(self(), {:stderr, stderr})
      end)

    assert_received {:status, status}
    assert_received {:stderr, stderr}
    %{status: status, stdout: stdout, stderr: stderr}
  end

  defp config(home, settings) do
    path = Path.join(home, ".lmx/config.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(Map.put(settings, "version", 1)))
    File.chmod!(path, 0o600)
    path
  end

  defp skill(root, name, description, extra \\ "") do
    write(
      Path.join(root, name),
      "SKILL.md",
      "---\nname: #{name}\ndescription: #{description}\n#{extra}---\nBody"
    )
  end

  defp write(directory, name, contents) do
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, name), contents)
  end

  defp link(target, path) do
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
  end
end
