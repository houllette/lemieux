defmodule Lemieux.Extensions.CheckpointsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.Tool
  alias Lemieux.Tools

  @moduletag :tmp_dir

  # A `write` that is only a write, so these tests say nothing about the
  # built-in tool's own policies.
  defmodule PlainWrite do
    @moduledoc false
    @behaviour Lemieux.Tool

    def name, do: "write"
    def description, do: "write a file"

    def schema,
      do: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}

    def run(%{"path" => path, "content" => content}, context) do
      File.write!(Path.join(context.cwd, path), content)
      {:ok, "wrote #{path}"}
    end
  end

  # A `bash` that starts nothing, for what the wrapper does around a call
  # rather than what a command does.
  defmodule FakeBash do
    @moduledoc false
    @behaviour Lemieux.Tool

    def name, do: "bash"
    def description, do: "pretend to run a command"

    def schema,
      do: %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}}

    def run(_args, _context), do: {:ok, "started"}
  end

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    %{
      store: Path.join(tmp_dir, "checkpoints"),
      work: work,
      ctx: %{cwd: work, session_id: "s1", call_id: "c1", environment: Lemieux.Environment.local()}
    }
  end

  defp init_repo(work, files) do
    git =
      &System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@e", "-c", "commit.gpgsign=false" | &1],
        cd: work
      )

    git.(["init", "-q"])
    Enum.each(files, fn {name, contents} -> File.write!(Path.join(work, name), contents) end)
    git.(["add", "-A"])
    git.(["commit", "-qm", "init"])
  end

  defp assemble(catalog, opts) do
    {:ok, harness} = Harness.assemble(Harness.new(tools: catalog), [{Checkpoints, opts}])
    harness
  end

  defp tool(harness, name) do
    {:ok, tool} = Tool.fetch(harness.tools, name)
    tool
  end

  defp prompt(harness, ctx), do: Hooks.user_prompt(harness.hooks, "next", ctx)

  test "a wrapped write can be undone", %{store: store, work: work, ctx: ctx} do
    File.write!(Path.join(work, "a.txt"), "before\n")
    harness = assemble([Tools.Read, PlainWrite], dir: store)

    assert {:ok, "next"} = prompt(harness, ctx)

    assert {:ok, "wrote a.txt"} =
             Tool.invoke(
               tool(harness, "write"),
               %{"path" => "a.txt", "content" => "after\n"},
               ctx
             )

    assert {:ok, [%{turn: 1, files: ["a.txt"]}]} = Checkpoint.list(store, "s1")
    assert {:ok, %{restored: ["a.txt"]}} = Checkpoint.undo(store, "s1")
    assert File.read!(Path.join(work, "a.txt")) == "before\n"
  end

  test "each prompt starts a turn", %{store: store, work: work, ctx: ctx} do
    harness = assemble([PlainWrite], dir: store)
    write = tool(harness, "write")

    prompt(harness, ctx)
    Tool.invoke(write, %{"path" => "one.txt", "content" => "1"}, ctx)
    prompt(harness, ctx)
    Tool.invoke(write, %{"path" => "two.txt", "content" => "2"}, %{ctx | call_id: "c2"})

    assert {:ok, %{turn: 2, deleted: ["two.txt"]}} = Checkpoint.undo(store, "s1")
    assert File.exists?(Path.join(work, "one.txt"))
  end

  test "apply_patch captures every file the patch touches", %{store: store, work: work, ctx: ctx} do
    File.write!(Path.join(work, "old.txt"), "x\n")
    harness = assemble([Tools.ApplyPatch], dir: store)
    prompt(harness, ctx)

    patch =
      "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n-x\n+y\n*** End Patch\n"

    assert {:ok, _result} = Tool.invoke(tool(harness, "apply_patch"), %{"input" => patch}, ctx)
    assert File.read!(Path.join(work, "new.txt")) == "y\n"

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.restored == ["old.txt"]
    assert report.deleted == ["new.txt"]
    assert File.read!(Path.join(work, "old.txt")) == "x\n"
    refute File.exists?(Path.join(work, "new.txt"))
  end

  test "with git, a command's changes are recorded once the command has finished", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    git =
      &System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@e", "-c", "commit.gpgsign=false" | &1],
        cd: work
      )

    git.(["init", "-q"])
    File.write!(Path.join(work, "tracked.txt"), "v0\n")
    git.(["add", "-A"])
    git.(["commit", "-qm", "init"])

    harness = assemble([Tools.Bash], dir: store, git: true)
    prompt(harness, ctx)

    bash = tool(harness, "bash")
    command = "sleep 0.2 && printf 'by bash\\n' > tracked.txt"
    assert {:ok, _output} = Tool.collect(Tool.invoke(bash, %{"command" => command}, ctx))
    assert File.read!(Path.join(work, "tracked.txt")) == "by bash\n"

    assert {:ok, %{restored: ["tracked.txt"]}} = Checkpoint.undo(store, "s1")
    assert File.read!(Path.join(work, "tracked.txt")) == "v0\n"
  end

  # Audit repro (gap-1-undo-safety-net-coverage): a command changes a file,
  # then a file tool changes it again in the same turn. /undo used to report
  # "restored" and leave the command's version in place.
  test "a file a command changed and then edit changed goes back to its state before the turn",
       %{store: store, work: work, ctx: ctx} do
    init_repo(work, %{"config.exs" => "port: 4000\n"})
    harness = assemble([Tools.Bash, Tools.Edit], dir: store, git: true)
    prompt(harness, ctx)

    command = "printf 'port: 4001\\n' > config.exs"

    assert {:ok, _output} =
             Tool.collect(Tool.invoke(tool(harness, "bash"), %{"command" => command}, ctx))

    edit = %{"path" => "config.exs", "old" => "port: 4001", "new" => "port: 4002"}
    ctx2 = %{ctx | call_id: "c2"}
    assert {:ok, _result} = Tool.collect(Tool.invoke(tool(harness, "edit"), edit, ctx2))
    assert File.read!(Path.join(work, "config.exs")) == "port: 4002\n"

    assert {:ok, %{restored: ["config.exs"], conflicts: []}} = Checkpoint.undo(store, "s1")
    assert File.read!(Path.join(work, "config.exs")) == "port: 4000\n"
  end

  # Audit repro: outside a git repository a command's changes are not
  # recorded, and undo used to answer "nothing to undo".
  test "outside a git repository, undo names the command it could not record",
       %{store: store, ctx: ctx} do
    # The ExUnit tmp_dir sits inside this repository's ignored tmp/, which is
    # itself a work tree; use a directory that no repository contains.
    work = Path.join(System.tmp_dir!(), "lmx-nongit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf(work) end)
    ctx = %{ctx | cwd: work}
    File.write!(Path.join(work, "notes.txt"), "keep me\n")
    harness = assemble([Tools.Bash], dir: store, git: true)
    prompt(harness, ctx)

    bash = tool(harness, "bash")
    assert {:ok, _output} = Tool.collect(Tool.invoke(bash, %{"command" => "rm notes.txt"}, ctx))
    refute File.exists?(Path.join(work, "notes.txt"))

    assert {:ok, %{restored: [], not_undone: [%{subject: "`rm notes.txt`", reason: reason}]}} =
             Checkpoint.undo(store, "s1")

    assert reason =~ "only in a git repository"
  end

  test "a command started in the background is noted", %{store: store, work: work, ctx: ctx} do
    init_repo(work, %{"tracked.txt" => "v0\n"})
    harness = assemble([FakeBash], dir: store, git: true)
    prompt(harness, ctx)

    args = %{"command" => "npm run dev", "background" => true}
    assert {:ok, "started"} = Tool.invoke(tool(harness, "bash"), args, ctx)

    assert {:ok, %{not_undone: [%{subject: "`npm run dev`", reason: reason}]}} =
             Checkpoint.undo(store, "s1")

    assert reason =~ "background"
  end

  test "an MCP tool's call is noted as unrecorded", %{store: store, work: work, ctx: ctx} do
    init_repo(work, %{"tracked.txt" => "v0\n"})
    harness = assemble([Tools.Read], dir: store, git: true)
    prompt(harness, ctx)

    call = %{id: "c1", name: "mcp__fs__write_file", arguments: %{"path" => "tracked.txt"}}
    context = Map.put(ctx, :tool_descriptor, %{"origin" => %{"type" => "mcp"}})
    assert :ok = Hooks.after_tool_call(harness.hooks, call, {:ok, "wrote"}, context)

    assert {:ok, %{not_undone: [%{subject: "mcp__fs__write_file", reason: reason}]}} =
             Checkpoint.undo(store, "s1")

    assert reason =~ "MCP"
  end

  # A formatter in a post-tool hook rewrites what the agent wrote; undo used to
  # call that "changed since the agent wrote it" and leave the file.
  test "a hook that rewrites a written file does not make undo refuse it", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    File.write!(Path.join(work, "a.ex"), "before\n")

    format = fn call, _result, context ->
      path = Path.join(context.cwd, call.arguments["path"])
      File.write!(path, String.upcase(File.read!(path)))
      :ok
    end

    {:ok, harness} =
      Harness.assemble(
        Harness.new(tools: [PlainWrite], hooks: [after_tool_call: format]),
        [{Checkpoints, dir: store}]
      )

    prompt(harness, ctx)
    call = %{id: "c1", name: "write", arguments: %{"path" => "a.ex", "content" => "after\n"}}
    context = Map.put(ctx, :tool_output_bytes, 100_000)
    assert %{error?: false} = Lemieux.Tools.run(harness.tools, harness.hooks, call, context)
    assert File.read!(Path.join(work, "a.ex")) == "AFTER\n"

    assert {:ok, %{restored: ["a.ex"], conflicts: []}} = Checkpoint.undo(store, "s1")
    assert File.read!(Path.join(work, "a.ex")) == "before\n"
  end

  test "wraps only the tools that are there, and the command tools only with git", %{
    store: store
  } do
    harness = assemble([Tools.Read, Tools.Bash, Tools.Eval], dir: store)
    assert harness.tools == [Tools.Read, Tools.Bash, Tools.Eval]

    harness = assemble([Tools.Read, Tools.Bash, Tools.Eval], dir: store, git: true)

    assert [Tools.Read, %Tool.Override{tool: Tools.Bash}, %Tool.Override{tool: Tools.Eval}] =
             harness.tools
  end

  test "a missing directory stops assembly" do
    assert {:error, {Checkpoints, message}} =
             Harness.assemble(Harness.new(), [{Checkpoints, []}])

    assert message =~ ":dir"
  end
end
