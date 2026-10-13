defmodule Lemieux.Extensions.Workspace.AssetReaderTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Extensions.Workspace
  alias Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Extensions.Workspace.AssetReader.Local
  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool

  @moduletag :tmp_dir

  defmodule Remote do
    @behaviour AssetReader

    @impl true
    def resolve(%{resolve_error: error}, _path), do: {:error, error}

    def resolve(state, path) do
      path =
        if Containment.inside?(path, state.host),
          do: state.remote <> String.replace_prefix(path, state.host, ""),
          else: path

      {:ok, Containment.real_path(path)}
    end

    @impl true
    def stat(_state, path), do: Local.stat(nil, path)

    @impl true
    def read_file(state, path, max_bytes) do
      send(state.owner, {:asset_read, path})

      case Map.get(state, :read_override) do
        nil -> Local.read_file(nil, path, max_bytes)
        :oversized -> {:ok, String.duplicate("x", max_bytes + 1)}
        override -> override
      end
    end

    @impl true
    def list_dir(_state, path, limit), do: Local.list_dir(nil, path, limit)
  end

  setup %{tmp_dir: root} do
    host = Path.join(root, "host")
    remote = Path.join(root, "remote")
    home = Path.join(remote, "home")

    for dir <- [host, remote],
        do:
          write(
            dir,
            "kit/SKILL.md",
            "---\nname: kit\ndescription: A kit.\n---\n#{Path.basename(dir)} body $ARGUMENTS"
          )

    write(remote, "kit/guide.md", "remote guide")
    {:ok, skill} = Skill.read(Path.join(host, "kit/SKILL.md"))
    state = %{host: host, remote: remote, owner: self()}
    reader = AssetReader.new({Remote, state}, roots: [remote], home: home)

    selector = fn
      {Remote, :active} -> {:ok, reader}
      _replaced -> {:error, :unavailable}
    end

    %{
      host: host,
      remote: remote,
      home: home,
      skill: skill,
      reader: reader,
      selector: selector,
      context: %{environment: {Remote, :active}, tool_output_bytes: 2_000}
    }
  end

  defp write(root, path, contents) do
    target = Path.join(root, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, contents)
  end

  test "rendering, substitutions and listings use the chosen reader namespace", ctx do
    assert {:ok, body} = Skill.render(ctx.skill, "task", reader: ctx.reader)
    assert body =~ "remote body task"
    refute body =~ "host body"
    assert body =~ "Skill directory: #{ctx.remote}/kit"
    assert body =~ "- guide.md"
    assert_receive {:asset_read, path}
    assert path == Path.join(ctx.remote, "kit/SKILL.md")
  end

  test "the tool selects from the effective environment and pages supporting files", ctx do
    write(ctx.remote, "kit/guide.md", Enum.map_join(1..120, "\n", &"remote guide line #{&1}"))
    tool = SkillTool.new([ctx.skill], asset_reader: ctx.selector)

    assert {:ok, first} =
             SkillTool.run(tool, %{"name" => "kit", "file" => "guide.md"}, ctx.context)

    assert first =~ "remote guide line 1"
    assert first =~ "part 1 of"
    refute first =~ "remote guide line 120"

    assert {:ok, second} =
             SkillTool.run(
               tool,
               %{"name" => "kit", "file" => "guide.md", "part" => 2},
               ctx.context
             )

    assert second =~ "remote guide line"
    refute second == first
  end

  test "unknown or replaced environments fail closed despite a readable host copy", ctx do
    tool = SkillTool.new([ctx.skill])
    assert {:error, reason} = SkillTool.run(tool, %{"name" => "kit"}, ctx.context)
    assert reason =~ "reader is unavailable"

    tool = SkillTool.new([ctx.skill], asset_reader: ctx.selector)
    assert {:ok, body} = SkillTool.run(tool, %{"name" => "kit"}, ctx.context)
    assert body =~ "remote body"

    assert {:error, reason} =
             SkillTool.run(tool, %{"name" => "kit"}, %{
               ctx.context
               | environment: {Remote, :replaced}
             })

    assert reason =~ "reader is unavailable"
  end

  test "a separately approved external root grants asset access without widening file tools",
       ctx do
    worktree = Path.join(ctx.remote, "work")
    File.mkdir_p!(worktree)

    assert {:error, :outside_worktree} =
             Environment.read_file(
               Environment.local(),
               worktree,
               Path.join(ctx.remote, "kit/guide.md")
             )

    denied =
      AssetReader.new({Remote, %{host: ctx.host, remote: ctx.remote, owner: self()}},
        roots: [worktree],
        home: ctx.home
      )

    assert {:error, reason} = Skill.file(ctx.skill, "guide.md", reader: denied)
    assert reason =~ "approved asset roots"
    assert {:ok, "remote guide"} = Skill.file(ctx.skill, "guide.md", reader: ctx.reader)
  end

  test "traversal and links out of the skill remain refused inside a broader asset capability",
       ctx do
    write(ctx.remote, "secret.md", "do not read")
    File.ln_s!("../secret.md", Path.join(ctx.remote, "kit/escape.md"))

    for file <- ["../secret.md", "escape.md"] do
      assert {:error, reason} = Skill.file(ctx.skill, file, reader: ctx.reader)
      assert reason =~ "outside the skill's directory"
    end
  end

  test "credential locations are resolved in the reader namespace", ctx do
    write(ctx.host, "home/SKILL.md", "---\nname: dotfiles\ndescription: Home.\n---\nBody")
    write(ctx.remote, "home/.ssh/key", "PRIVATE")
    {:ok, skill} = Skill.read(Path.join(ctx.host, "home/SKILL.md"))
    assert {:error, reason} = Skill.file(skill, ".ssh/key", reader: ctx.reader)
    assert reason =~ "~/.ssh"
    refute reason =~ "PRIVATE"
  end

  test "repository checks and symlink changes are revalidated with the same reader", ctx do
    scope = Containment.scope(ctx.host, Path.dirname(ctx.host))
    skill = %{ctx.skill | within: scope}
    assert {:ok, body} = Skill.render(skill, "", reader: ctx.reader)
    assert body =~ "remote body"
    outside = Path.join(Path.dirname(ctx.remote), "outside.md")
    File.write!(outside, "SECRET")
    File.rm!(Path.join(ctx.remote, "kit/SKILL.md"))
    File.ln_s!(outside, Path.join(ctx.remote, "kit/SKILL.md"))
    assert {:error, _reason} = Skill.render(skill, "", reader: ctx.reader)
    refute_received {:asset_read, ^outside}
  end

  test "reader failures and oversized results cannot fall back or expose backend state", ctx do
    {module, state} = ctx.reader.implementation

    for {override, message} <- [
          {:oversized, "read limit"},
          {{:error, {:transport, "SECRET TOKEN"}}, "could not complete"}
        ] do
      reader = %{ctx.reader | implementation: {module, Map.put(state, :read_override, override)}}
      assert {:error, reason} = Skill.render(ctx.skill, "", reader: reader)
      assert reason =~ message
      refute reason =~ "SECRET TOKEN"
      refute reason =~ "host body"
    end

    missing = %{ctx.reader | implementation: {__MODULE__, nil}}
    assert {:error, reason} = Skill.render(ctx.skill, "", reader: missing)
    assert reason =~ "reader is unavailable"
  end

  test "bounded listings advertise incomplete results and never include dotfiles", ctx do
    for number <- 1..60, do: write(ctx.remote, "kit/guide-#{number}.md", "guide")
    write(ctx.remote, "kit/.private", "SECRET")
    assert {:ok, rendered} = Skill.render(ctx.skill, "", reader: ctx.reader)
    assert rendered =~ "more files"
    refute rendered =~ "- SKILL.md"
    refute rendered =~ ".private"
    assert length(Regex.scan(~r/^- guide/m, rendered)) == 50
  end

  test "workspace configuration carries the selector to native and model loaders", ctx do
    workspace = %Discovery{root: ctx.host, skills: [ctx.skill]}
    assert {:ok, selected} = Workspace.init(workspace: workspace, asset_reader: ctx.selector)
    assert [skill] = selected.skills
    assert {:ok, rendered} = Skill.render(skill, "", environment: ctx.context.environment)
    assert rendered =~ "remote body"
    assert [%SkillTool{} = tool] = Discovery.host_tools(selected)
    assert {:ok, rendered} = SkillTool.run(tool, %{"name" => "kit"}, ctx.context)
    assert rendered =~ "remote body"
  end

  test "resolution failures cannot expose arbitrary backend error text", ctx do
    {module, state} = ctx.reader.implementation

    reader = %{
      ctx.reader
      | implementation: {module, Map.put(state, :resolve_error, "SECRET TOKEN")}
    }

    assert {:error, reason} = Skill.render(ctx.skill, "", reader: reader)
    refute reason =~ "SECRET TOKEN"
    assert reason =~ "could not complete"

    assert {:error, reason} = Skill.file(ctx.skill, "guide.md", reader: reader)
    refute reason =~ "SECRET TOKEN"
    assert reason =~ "could not complete"
  end
end
