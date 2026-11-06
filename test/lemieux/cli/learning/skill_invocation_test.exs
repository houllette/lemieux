defmodule Lemieux.CLI.Learning.SkillInvocationTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetSearch
  alias Lemieux.CLI.Learning.SkillInvocation
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

  @moduletag :tmp_dir
  @task "Normalize archive paths safely"
  @body "Read the current source before changing its parser."

  setup %{tmp_dir: dir} do
    context = %{
      scope: %{"id" => "trigger-test"},
      binding: %{"runtime_sha256" => Lemieux.Contract.sha256("runtime")},
      trust: "personal",
      tools: ["read"],
      description_tools: [],
      settings_allowlist: [],
      approved_digests: []
    }

    assert {:ok, version} =
             Asset.new(
               %{
                 "kind" => "skill",
                 "payload" => %{"name" => "archive-repair"},
                 "requires_tools" => ["read"],
                 "triggers" => ["archive paths"],
                 "files" => %{
                   "SKILL.md" =>
                     "---\nname: archive-repair\ndescription: Use for archive paths.\n---\n#{@body}\n"
                 }
               },
               context
             )

    assert {:ok, _} = Asset.materialize(version, Path.join(dir, version.id), context)

    item = %{
      version: version,
      review: %{"decision" => "approve", "asset_sha256" => version.digest}
    }

    context = %{context | approved_digests: [version.digest]}
    base = Harness.new(system: "Solve the task", tools: [Read, Write])

    assert {:ok, loaded} =
             AssetSearch.apply([item], base, context, dir, Lemieux.Environment.local())

    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{harness: loaded, assets: [item], runtime: runtime}
  end

  test "a matched task exposes the selected loader first and restores tools after a real read",
       ctx do
    provider =
      Scripted.new([
        fn request ->
          assert Enum.map(request.tools, &Tool.name/1) == ["skill"]
          refute request.system =~ @body
          Scripted.complete("done")
        end,
        fn request ->
          assert Enum.map(request.tools, &Tool.name/1) == ["skill"]
          Scripted.tool_call("load", "skill", %{"name" => "archive-repair"})
        end,
        fn request ->
          assert "read" in Enum.map(request.tools, &Tool.name/1)

          assert Enum.any?(
                   request.entries,
                   &(&1.type == :tool_result and &1.payload["output"] =~ @body)
                 )

          Scripted.complete("done")
        end
      ])

    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)
    assert length(run(ctx, provider, harness, @task)) == 3

    assert harness.harness_context["asset_invocation"]["skills"] == [
             %{"name" => "archive-repair", "sha256" => hd(ctx.assets).version.digest}
           ]
  end

  test "an unrelated prompt keeps its ordinary tools and gets no invocation feedback", ctx do
    provider = Scripted.new([Scripted.complete("done")])
    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)
    [request] = run(ctx, provider, harness, "Repair a calendar")
    assert "read" in Enum.map(request.tools, &Tool.name/1)
  end

  test "a model that ignores the loader receives at most one bounded continuation", ctx do
    provider = Scripted.new([Scripted.complete("declined"), Scripted.complete("still declined")])
    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)
    assert length(run(ctx, provider, harness, @task)) == 2
  end

  test "an earlier prompt's read does not satisfy the next prompt's invocation", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("first", "skill", %{"name" => "archive-repair"}),
        Scripted.complete("done"),
        fn request ->
          assert Enum.map(request.tools, &Tool.name/1) == ["skill"]
          Scripted.tool_call("second", "skill", %{"name" => "archive-repair"})
        end,
        Scripted.complete("done")
      ])

    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: JSONL.new(Path.join(ctx.tmp_dir, "sessions")),
        provider: provider,
        model: "test:skill",
        harness: harness,
        subscriber: self()
      )

    id = Session.id(session)

    for _ <- 1..2 do
      :ok = Session.prompt(session, @task)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    assert length(Scripted.requests(provider)) == 4
  end

  test "invocation feedback cannot add a request outside the session's turn ceiling", ctx do
    provider = Scripted.new([Scripted.complete("declined")])
    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: JSONL.new(Path.join(ctx.tmp_dir, "sessions")),
        provider: provider,
        model: "test:skill",
        harness: harness,
        max_turns: 1,
        subscriber: self()
      )

    id = Session.id(session)
    :ok = Session.prompt(session, @task)
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    assert length(Scripted.requests(provider)) == 1
  end

  test "a host denial remains a denial and releases the ordinary catalog without retrying", ctx do
    harness =
      ctx.harness
      |> Harness.append_hooks(before_tool_call: fn _call, _context -> {:deny, "host refused"} end)
      |> SkillInvocation.configure(ctx.assets, @task)

    provider =
      Scripted.new([
        Scripted.tool_call("load", "skill", %{"name" => "archive-repair"}),
        fn request ->
          assert "read" in Enum.map(request.tools, &Tool.name/1)

          assert Enum.any?(
                   request.entries,
                   &(&1.type == :tool_result and &1.payload["error"] == true)
                 )

          Scripted.complete("done")
        end
      ])

    assert length(run(ctx, provider, harness, @task)) == 2
  end

  test "an undisclosed write cannot bypass the host's selected-procedure prerequisite", ctx do
    target = Path.join(ctx.tmp_dir, "output.txt")

    provider =
      Scripted.new([
        Scripted.tool_call("early", "write", %{"path" => "output.txt", "content" => "bypassed"}),
        fn request ->
          refute File.exists?(target)

          assert Enum.any?(
                   request.entries,
                   &(&1.type == :tool_result and &1.payload["error"] == true)
                 )

          Scripted.tool_call("load", "skill", %{"name" => "archive-repair"})
        end,
        Scripted.tool_call("later", "write", %{"path" => "output.txt", "content" => "approved"}),
        Scripted.complete("done")
      ])

    harness = SkillInvocation.configure(ctx.harness, ctx.assets, @task)
    assert length(run(ctx, provider, harness, @task)) == 4
    assert File.read!(target) == "approved"
  end

  test "loading a procedure cannot override the host's write denial", ctx do
    target = Path.join(ctx.tmp_dir, "denied.txt")

    harness =
      ctx.harness
      |> Harness.append_hooks(
        before_tool_call: fn
          %{name: "write"}, _context -> {:deny, "host refused write"}
          _call, _context -> :allow
        end
      )
      |> SkillInvocation.configure(ctx.assets, @task)

    provider =
      Scripted.new([
        Scripted.tool_call("load", "skill", %{"name" => "archive-repair"}),
        Scripted.tool_call("write", "write", %{"path" => "denied.txt", "content" => "forbidden"}),
        fn request ->
          assert Enum.any?(
                   request.entries,
                   &(&1.type == :tool_result and &1.payload["name"] == "write" and
                       &1.payload["error"] == true)
                 )

          Scripted.complete("done")
        end
      ])

    assert length(run(ctx, provider, harness, @task)) == 3
    refute File.exists?(target)
  end

  test "paged bodies need all pages, and missing or truncated output is not a complete read" do
    first =
      read(
        1,
        "Skill: archive-repair\nFirst\n\n[Skill archive-repair: part 1 of 2. Call skill again with \"part\": 2 for the rest before acting on it.]"
      )

    last = read(2, "Last\n\n[Skill archive-repair: part 2 of 2, the end.]")
    refute SkillInvocation.loaded?([first], "archive-repair")

    with_feedback =
      update_in(first, ["payload"], fn payload ->
        text = payload["output"] <> "\n\nHost feedback"
        Map.merge(payload, %{"output" => text, "output_bytes" => byte_size(text)})
      end)

    refute SkillInvocation.loaded?([with_feedback], "archive-repair")
    refute SkillInvocation.loaded?([last], "archive-repair")
    assert SkillInvocation.loaded?([first, last], "archive-repair")
    refute SkillInvocation.loaded?([put_in(first, ["payload", "output"], nil)], "archive-repair")

    refute SkillInvocation.loaded?(
             [put_in(first, ["payload", "output_bytes"], 100_000), last],
             "archive-repair"
           )

    refute SkillInvocation.loaded?(
             [
               read(
                 1,
                 "Skill: archive-repair\n\n[Skill archive-repair: part 1 of 999999999999999999999, the end.]"
               )
             ],
             "archive-repair"
           )
  end

  defp read(part, output),
    do: %{
      "type" => "tool_result",
      "payload" => %{
        "name" => "skill",
        "arguments" => %{"name" => "archive-repair", "part" => part},
        "error" => false,
        "output" => output,
        "output_bytes" => byte_size(output)
      }
    }

  defp run(ctx, provider, harness, prompt) do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: JSONL.new(Path.join(ctx.tmp_dir, "sessions")),
        provider: provider,
        model: "test:skill",
        harness: harness,
        cwd: ctx.tmp_dir,
        max_requests: 6,
        subscriber: self()
      )

    id = Session.id(session)
    :ok = Session.prompt(session, prompt)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    Scripted.requests(provider)
  end
end
