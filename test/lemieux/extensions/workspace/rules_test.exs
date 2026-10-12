defmodule Lemieux.Extensions.Workspace.RulesTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Compatibility
  alias Lemieux.Extensions.Workspace
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.Write

  @moduletag :tmp_dir

  defp rule(dir, name, text) do
    path = Path.join([dir, ".claude", "rules", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  defp discover(dir) do
    File.mkdir_p!(Path.join(dir, ".git"))
    assert {:ok, workspace} = Discovery.discover(dir, personal?: false, bundled_skills?: false)
    workspace
  end

  defp session(dir, workspace, provider) do
    runtime = :"scoped_rules_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    harness = Workspace.apply(Harness.new(tools: [Write]), workspace)

    opts = [
      supervisor: runtime,
      provider: provider,
      store: JSONL.new(Path.join(dir, "sessions")),
      model: "test:model",
      cwd: dir,
      harness: harness
    ]

    assert {:ok, session} = Lemieux.start_session(opts)
    {session, opts}
  end

  test "scoped guidance is visible before a first write can land", %{tmp_dir: dir} do
    rule(
      dir,
      "api.md",
      "---\npaths:\n  - src/**/*.{ts,tsx}\n---\nRULE-CANARY: validate API input"
    )

    workspace = discover(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    call = Scripted.tool_call("write", "write", %{"path" => "src/api.ts", "content" => "safe"})

    provider =
      Scripted.new([
        call,
        fn request ->
          refute File.exists?(Path.join(dir, "src/api.ts"))
          assert request.system =~ "RULE-CANARY"
          call
        end,
        Scripted.complete("done")
      ])

    {session, _opts} = session(dir, workspace, provider)
    assert {:ok, result} = Lemieux.Testing.prompt(session, "work")
    assert File.read!(Path.join(dir, "src/api.ts")) == "safe"

    assert Enum.any?(
             result.entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )

    refute hd(Scripted.requests(provider)).system =~ "RULE-CANARY"

    assert {:ok, %{value: %{"active" => [_digest]}}} =
             Session.document(session, "lemieux.workspace_rules")
  end

  test "root-anchored globs do not activate on unrelated nested files", %{tmp_dir: dir} do
    rule(dir, "markdown.md", "---\npaths: '*.md'\n---\nROOT-MARKDOWN-CANARY")
    File.mkdir_p!(Path.join(dir, "nested"))

    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{"path" => "nested/doc.md", "content" => "nested"}),
        Scripted.complete("done")
      ])

    {session, _opts} = session(dir, discover(dir), provider)
    assert {:ok, _result} = Lemieux.Testing.prompt(session, "work")
    assert File.read!(Path.join(dir, "nested/doc.md")) == "nested"

    refute Enum.any?(
             Scripted.requests(provider),
             &String.contains?(&1.system, "ROOT-MARKDOWN-CANARY")
           )

    assert {:ok, %{value: nil}} = Session.document(session, "lemieux.workspace_rules")
  end

  test "global rules load while malformed scopes and external symlinks are diagnosed", %{
    tmp_dir: dir
  } do
    rule(dir, "global.md", "GLOBAL-CANARY")
    rule(dir, "malformed.md", "---\npaths: 123\n---\nMALFORMED-CANARY")
    outside = Path.join(System.tmp_dir!(), "rule-secret-#{System.unique_integer([:positive])}")
    File.write!(outside, "OUTSIDE-SECRET-CANARY")
    on_exit(fn -> File.rm(outside) end)
    link = rule(dir, "outside.md", "placeholder")
    File.rm!(link)
    File.ln_s!(outside, link)
    workspace = discover(dir)
    prompt = Discovery.system_prompt(workspace, "base")
    assert prompt =~ "GLOBAL-CANARY"
    refute prompt =~ "MALFORMED-CANARY"
    refute prompt =~ "OUTSIDE-SECRET-CANARY"
    assert length(workspace.diagnostics) == 2
    assert Enum.all?(workspace.diagnostics, &String.contains?(&1, "rule skipped"))
    report = Compatibility.report(workspace) |> JSON.encode!()
    refute report =~ "GLOBAL-CANARY"
    refute report =~ "OUTSIDE-SECRET-CANARY"
  end

  test "resume uses a changed rule body and activates its new digest", %{tmp_dir: dir} do
    path = rule(dir, "api.md", "---\npaths: src/**\n---\nOLD-RULE-CANARY")
    File.mkdir_p!(Path.join(dir, "src"))

    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{"path" => "src/old", "content" => "x"}),
        Scripted.complete("loaded")
      ])

    {session, opts} = session(dir, discover(dir), provider)
    assert {:ok, _result} = Lemieux.Testing.prompt(session, "load")
    id = Session.id(session)
    GenServer.stop(session)
    File.write!(path, "---\npaths: src/**\n---\nNEW-RULE-CANARY")
    call = Scripted.tool_call("write", "write", %{"path" => "src/new", "content" => "x"})

    provider =
      Scripted.new([
        call,
        fn request ->
          assert request.system =~ "NEW-RULE-CANARY"
          refute request.system =~ "OLD-RULE-CANARY"
          Scripted.complete("updated")
        end
      ])

    harness = Workspace.apply(Harness.new(tools: [Write]), discover(dir))

    assert {:ok, resumed} =
             Lemieux.resume_session(
               Keyword.merge(opts, resume: id, harness: harness, provider: provider)
             )

    assert {:ok, _result} = Lemieux.Testing.prompt(resumed, "continue")
    refute File.exists?(Path.join(dir, "src/new"))
    assert length(Scripted.requests(provider)) == 2
  end
end
