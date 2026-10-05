defmodule CaptureExtensionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CaptureExtension.Config
  alias CaptureExtension.Draft
  alias Lemieux.Benchmark.Corpus.Promote
  alias Lemieux.Entry
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/value.ex"), "defmodule Value, do: def get, do: 1\n")
    File.write!(Path.join(workspace, "README.md"), "# fixture\n")
    File.mkdir_p!(Path.join(workspace, "_build/dev"))
    File.write!(Path.join(workspace, "_build/dev/junk"), String.duplicate("j", 500))

    sessions_dir = Path.join(tmp_dir, "sessions")
    feedback_dir = Path.join(tmp_dir, "feedback")
    store = JSONL.new(sessions_dir)

    {:ok, config} =
      Config.new(
        sessions_dir: sessions_dir,
        feedback_dir: feedback_dir,
        store: store,
        feedback_store: FeedbackJSONL.new(feedback_dir)
      )

    %{
      workspace: workspace,
      store: store,
      config: config,
      session_id: Lemieux.ID.generate(),
      drafts: Path.join(workspace, ".lmx/drafts")
    }
  end

  describe "a failing verification" do
    test "produces one mechanical draft whose verifier is the failing command", context do
      entries = [user("make value 2"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, %Draft{} = draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      assert draft.class == :mechanical
      assert draft.path == Path.join(context.drafts, draft.id)
      assert [_only] = drafts(context)

      record = read_json(Path.join(draft.path, "draft.json"))
      assert record["status"] == "draft"
      assert record["feedback_id"] == draft.feedback_id
      assert record["task"]["grader"]["command"] == ["sh", "-c", "mix test"]
      assert record["task"]["prompt"] =~ "make value 2"
      assert record["task"]["prompt"] =~ "`mix test` must exit 0"
      assert record["task"]["cwd"] == "fixture"

      fixture = Path.join(draft.path, "fixture")
      assert File.read!(Path.join(fixture, "lib/value.ex")) =~ "Value"
      refute File.exists?(Path.join(fixture, "_build"))

      assert {:ok, feedback} =
               FeedbackStore.latest(context.config.feedback_store, draft.feedback_id)

      assert feedback.verifiability["class"] == "mechanical"
      assert feedback.verifiability["source"] == "verification_command"
      assert feedback.actor == %{"type" => "hook", "id" => "capture-extension"}
      assert feedback.type == :bug
      assert feedback.status == :captured
      assert feedback.provenance["host"] == "capture"
      assert feedback.provenance["session_id"] == context.session_id
      assert feedback.provenance["entry_id"] == draft.signal.anchor_entry_id
      assert feedback.provenance["tool_call_id"] == "c1"

      assert [%{"kind" => "verification_failure", "exit_status" => 1}] =
               feedback.provenance["signals"]
    end

    test "records the snapshot beside the draft, including what it skipped", context do
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      capture = read_json(Path.join(draft.path, "capture.json"))
      assert capture["class"] == "mechanical"
      assert capture["session_id"] == context.session_id
      assert capture["signal"]["command"] == "mix test"
      assert capture["snapshot"]["files"] == 2

      # The drafts directory exists by the time the workspace is copied, so
      # it is recorded as excluded rather than silently absent.
      assert Enum.sort_by(capture["snapshot"]["skipped"], & &1["path"]) == [
               %{"path" => ".lmx/drafts", "reason" => "excluded"},
               %{"path" => "_build", "reason" => "skipped_directory"}
             ]

      assert capture["promote"] == draft.promote
      refute File.exists?(Path.join(context.drafts, ".staging-" <> draft.id))
    end

    test "is suppressed by a later passing run", context do
      entries = [
        user("go"),
        bash_call("c1", "mix test"),
        bash_result("c1", 1),
        bash_call("c2", "mix test"),
        bash_result("c2", 0)
      ]

      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, nil} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      refute File.exists?(context.drafts)
      assert {:ok, []} = FeedbackStore.list_feedback(context.config.feedback_store)
    end

    test "bounds the fixture and records a file that was too large", context do
      File.write!(Path.join(context.workspace, "dump.bin"), String.duplicate("d", 2 * 1_048_576))
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      refute File.exists?(Path.join([draft.path, "fixture", "dump.bin"]))
      assert File.exists?(Path.join([draft.path, "fixture", "README.md"]))

      assert %{"path" => "dump.bin", "reason" => "too_large", "bytes" => 2_097_152} =
               Enum.find(draft.snapshot["skipped"], &(&1["path"] == "dump.bin"))

      capture = read_json(Path.join(draft.path, "capture.json"))
      assert Enum.any?(capture["snapshot"]["skipped"], &(&1["reason"] == "too_large"))
    end

    test "does not copy the drafts directory into its own fixture", context do
      File.mkdir_p!(Path.join(context.drafts, "case_old/fixture"))
      File.write!(Path.join(context.drafts, "case_old/fixture/x"), "x")
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      refute File.exists?(Path.join([draft.path, "fixture", ".lmx", "drafts"]))

      assert [%{"path" => ".lmx/drafts", "reason" => "excluded"}] =
               Enum.filter(draft.snapshot["skipped"], &(&1["reason"] == "excluded"))
    end

    test "keeps credentials out of the fixture and records each one it left out", context do
      File.write!(Path.join(context.workspace, ".env"), "OPENAI_API_KEY=placeholder\n")
      File.write!(Path.join(context.workspace, ".env.example"), "OPENAI_API_KEY=\n")
      File.mkdir_p!(Path.join(context.workspace, "config"))
      File.write!(Path.join(context.workspace, "config/prod.secret.exs"), "import Config\n")
      File.write!(Path.join(context.workspace, "lib/server.pem"), "-----BEGIN-----\n")
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      fixture = Path.join(draft.path, "fixture")
      assert File.read!(Path.join(fixture, ".env.example")) == "OPENAI_API_KEY=\n"
      assert File.exists?(Path.join(fixture, "lib/value.ex"))

      for secret <- [".env", "config/prod.secret.exs", "lib/server.pem"] do
        refute File.exists?(Path.join(fixture, secret)), "#{secret} was copied"
      end

      capture = read_json(Path.join(draft.path, "capture.json"))

      assert capture["snapshot"]["skipped"]
             |> Enum.filter(&(&1["reason"] == "secret"))
             |> Enum.map(& &1["path"])
             |> Enum.sort() == [".env", "config/prod.secret.exs", "lib/server.pem"]
    end
  end

  describe "the drafts directory" do
    test "ignores everything in it, so a workspace copy is never staged by git add",
         context do
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, _draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      assert File.read!(Path.join(context.drafts, ".gitignore")) == "*\n"
    end

    test "keeps a .gitignore the person already wrote", context do
      File.mkdir_p!(context.drafts)
      File.write!(Path.join(context.drafts, ".gitignore"), "case_*/fixture/\n")
      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, _draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      assert File.read!(Path.join(context.drafts, ".gitignore")) == "case_*/fixture/\n"
    end
  end

  describe "a correction" do
    test "produces a needs-review draft that promote cannot take as it is", context do
      entries = [user("rename the flag"), assistant("renamed"), user("No, that's the wrong flag")]
      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, %Draft{class: :needs_review} = draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      record = read_json(Path.join(draft.path, "draft.json"))
      assert record["needs_review"] == true
      assert record["status"] == "draft"
      refute Map.has_key?(record, "task")
      assert record["suggested_prompt"] =~ "rename the flag"
      assert record["suggested_prompt"] =~ "wrong flag"
      assert File.exists?(Path.join([draft.path, "fixture", "README.md"]))

      assert {:error, :invalid_draft} =
               Promote.promote(
                 draft.path,
                 Path.join(context.tmp_dir, "manifest.json"),
                 cluster_id: "c"
               )

      assert {:ok, feedback} =
               FeedbackStore.latest(context.config.feedback_store, draft.feedback_id)

      assert feedback.verifiability == %{"class" => "unknown", "source" => "user_correction"}
      assert feedback.type == :unknown
      assert feedback.raw_text =~ "wrong flag"
      assert feedback.provenance["entry_id"] == draft.signal.anchor_entry_id
      refute Map.has_key?(feedback.provenance, "tool_call_id")

      assert draft.line =~ "for review"

      assert draft.line =~
               "lmx feedback draft-case #{draft.feedback_id} --source #{draft.path}/fixture"

      assert draft.line =~ "lmx corpus promote"
    end

    test "yields to a verification failure in the same session, which keeps the correction as evidence",
         context do
      entries = [
        user("go"),
        assistant("ok"),
        user("wrong, use make"),
        bash_call("c1", "make test"),
        bash_result("c1", 2)
      ]

      :ok = Store.append(context.store, context.session_id, entries)

      assert {:ok, %Draft{class: :mechanical} = draft} =
               CaptureExtension.capture(context.session_id, context.workspace, context.config)

      assert {:ok, feedback} =
               FeedbackStore.latest(context.config.feedback_store, draft.feedback_id)

      assert ["verification_failure", "correction"] =
               Enum.map(feedback.provenance["signals"], & &1["kind"])
    end
  end

  test "a clean session writes nothing at all", context do
    entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 0), assistant("done")]
    :ok = Store.append(context.store, context.session_id, entries)

    assert {:ok, nil} =
             CaptureExtension.capture(context.session_id, context.workspace, context.config)

    refute File.exists?(context.drafts)
    refute File.exists?(context.config.feedback_dir)
  end

  test "a session the store never saw is nothing to draft", context do
    assert {:ok, nil} = CaptureExtension.capture("01UNKNOWN", context.workspace, context.config)
  end

  test "creates a nested drafts directory on demand", context do
    {:ok, config} = Config.new(Keyword.merge(config_opts(context), drafts_dir: "var/lmx/drafts"))
    entries = [user("go"), bash_call("c1", "pytest"), bash_result("c1", 1)]
    :ok = Store.append(context.store, context.session_id, entries)

    assert {:ok, draft} = CaptureExtension.capture(context.session_id, context.workspace, config)
    assert draft.path == Path.join([context.workspace, "var/lmx/drafts", draft.id])
    assert File.dir?(Path.join(draft.path, "fixture"))
  end

  test "an absolute drafts directory is used as given", context do
    drafts = Path.join(context.tmp_dir, "elsewhere")
    {:ok, config} = Config.new(Keyword.merge(config_opts(context), drafts_dir: drafts))
    entries = [user("go"), bash_call("c1", "cargo test"), bash_result("c1", 101)]
    :ok = Store.append(context.store, context.session_id, entries)

    assert {:ok, draft} = CaptureExtension.capture(context.session_id, context.workspace, config)
    assert draft.path == Path.join(drafts, draft.id)
  end

  describe "hooks/1" do
    test "prints the draft path and the promote command on one stderr line", context do
      entries = [user("go"), bash_call("c1", "go test ./..."), bash_result("c1", 1)]
      :ok = Store.append(context.store, context.session_id, entries)

      [session_end: hook] = CaptureExtension.hooks(config_opts(context))
      hook_context = %{session_id: context.session_id, cwd: context.workspace}

      stderr = capture_io(:stderr, fn -> hook.(:normal, hook_context) end)

      [line] = String.split(String.trim(stderr), "\n")
      [draft_id] = drafts(context)
      path = Path.join(context.drafts, draft_id)

      assert line ==
               "capture: drafted #{path} (`go test ./...` exited 1); review it, then: " <>
                 "lmx corpus promote #{path} MANIFEST --cluster CLUSTER"
    end

    test "is silent for a clean session", context do
      :ok = Store.append(context.store, context.session_id, [user("hi"), assistant("hello")])
      [session_end: hook] = CaptureExtension.hooks(config_opts(context))

      assert capture_io(:stderr, fn ->
               hook.(:normal, %{session_id: context.session_id, cwd: context.workspace})
             end) == ""
    end

    test "rejects an invalid option when the hook is built, not at session end" do
      assert_raise ArgumentError, ~r/max_file_bytes/, fn ->
        CaptureExtension.hooks(max_file_bytes: 0)
      end
    end
  end

  describe "at the end of a real session" do
    test "a verification the model ran and left failing becomes a draft", context do
      runtime = :"capture_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})

      File.mkdir_p!(Path.join(context.workspace, "tests"))

      File.write!(
        Path.join(context.workspace, "tests/run.sh"),
        "#!/bin/sh\necho failing\nexit 1\n"
      )

      provider =
        Scripted.new([
          Scripted.tool_call("c1", "bash", %{"command" => "sh tests/run.sh"}),
          Scripted.complete("The tests fail; I am out of ideas.")
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          tools: [Lemieux.Tools.Bash],
          cwd: context.workspace,
          hooks: CaptureExtension.hooks(config_opts(context))
        )

      :ok = Session.prompt(session, "make the tests pass")
      assert_receive {:lemieux, _id, {:finished, :stop}}
      session_id = Session.id(session)

      capture_io(:stderr, fn ->
        assert :ok =
                 DynamicSupervisor.terminate_child(
                   Lemieux.Supervisor.session_supervisor(runtime),
                   session
                 )
      end)

      assert [draft_id] = drafts(context)
      record = read_json(Path.join([context.drafts, draft_id, "draft.json"]))
      assert record["task"]["grader"]["command"] == ["sh", "-c", "sh tests/run.sh"]
      assert record["provenance"]["session_id"] == session_id

      assert File.read!(Path.join([context.drafts, draft_id, "fixture", "tests/run.sh"])) =~
               "exit 1"
    end
  end

  defp config_opts(context) do
    [
      sessions_dir: context.config.sessions_dir,
      feedback_dir: context.config.feedback_dir,
      store: context.store,
      feedback_store: context.config.feedback_store
    ]
  end

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()

  # The drafts in the drafts directory, without the `.gitignore` beside them.
  defp drafts(context), do: context.drafts |> File.ls!() |> Enum.reject(&(&1 == ".gitignore"))

  defp user(text), do: Entry.new(:user, %{"text" => text})

  defp assistant(text),
    do: Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => text}]})

  defp bash_call(id, command) do
    Entry.new(:assistant, %{
      "content" => [],
      "tool_calls" => [%{"id" => id, "name" => "bash", "arguments" => %{"command" => command}}]
    })
  end

  defp bash_result(id, exit_status) do
    Entry.new(:tool_result, %{
      "call_id" => id,
      "name" => "bash",
      "arguments" => %{},
      "output" => "[exit status #{exit_status}]",
      "error" => false,
      "structured_content" => %{"status" => "exited", "exit_status" => exit_status}
    })
  end
end
