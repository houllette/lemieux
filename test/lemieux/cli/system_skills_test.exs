defmodule Lemieux.CLI.SystemSkillsTest do
  @moduledoc """
  Where `lmx` finds Omarchy's skills. Every machine here is described by
  options — `OMARCHY_PATH`, the home directory, the packaged location — so
  nothing reads `/usr/share/omarchy` or this machine's environment.
  """
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.SystemSkills

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{
      home: Path.join(tmp_dir, "home"),
      packaged: Path.join(tmp_dir, "usr/share/omarchy"),
      custom: Path.join(tmp_dir, "custom-omarchy")
    }
  end

  defp skills(install), do: Path.join(install, "default/agents/skills")
  defp install(install), do: File.mkdir_p!(skills(install))

  defp machine(ctx, env),
    do: [env: env, home: ctx.home, packaged: ctx.packaged]

  test "OMARCHY_PATH comes first when its skills directory exists", ctx do
    install(ctx.custom)
    install(ctx.packaged)

    assert SystemSkills.roots(nil, machine(ctx, %{"OMARCHY_PATH" => ctx.custom})) == [
             skills(ctx.custom)
           ]
  end

  test "an OMARCHY_PATH without skills falls through to the packaged install", ctx do
    File.mkdir_p!(ctx.custom)
    install(ctx.packaged)

    assert SystemSkills.roots(nil, machine(ctx, %{"OMARCHY_PATH" => ctx.custom})) == [
             skills(ctx.packaged)
           ]
  end

  test "unset, the packaged install, then an older one in ~/.local/share", ctx do
    older = Path.join(ctx.home, ".local/share/omarchy")
    install(older)

    assert SystemSkills.roots(nil, machine(ctx, %{})) == [skills(older)]

    install(ctx.packaged)

    assert SystemSkills.roots(nil, machine(ctx, %{"OMARCHY_PATH" => "  "})) == [
             skills(ctx.packaged)
           ]
  end

  test "no Omarchy, no roots, and the report says where it looked", ctx do
    assert SystemSkills.roots(nil, machine(ctx, %{"OMARCHY_PATH" => ctx.custom})) == []

    assert %{omarchy: %{enabled?: true, root: nil, candidates: candidates}} =
             SystemSkills.report(nil, machine(ctx, %{"OMARCHY_PATH" => ctx.custom}))

    assert candidates == [
             skills(ctx.custom),
             skills(ctx.packaged),
             skills(Path.join(ctx.home, ".local/share/omarchy"))
           ]
  end

  test ~s("skills": {"omarchy": false} turns the roots off), %{tmp_dir: tmp_dir} = ctx do
    install(ctx.packaged)
    path = Path.join(tmp_dir, "config.json")
    File.write!(path, ~s({"skills": {"omarchy": false}}))
    File.chmod!(path, 0o600)
    {:ok, config} = Config.load(path)

    refute SystemSkills.omarchy?(config)
    assert SystemSkills.roots(config, machine(ctx, %{})) == []

    assert %{omarchy: %{enabled?: false, root: nil}} =
             SystemSkills.report(config, machine(ctx, %{}))

    # Without the switch, the same machine has them.
    assert SystemSkills.roots(nil, machine(ctx, %{})) == [skills(ctx.packaged)]
  end
end
