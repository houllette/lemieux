defmodule Lemieux.CLI.BugReportTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.BugReport
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Feedback
  alias Lemieux.Diagnostic
  alias Lemieux.Entry
  alias Lemieux.Feedback.Store, as: Store
  alias Lemieux.Feedback.Store.JSONL

  @moduletag :tmp_dir

  defp snapshot do
    diagnostic =
      Diagnostic.new(
        "tool",
        "private text",
        {RuntimeError.exception("secret sk-test123 /home/private/code"),
         [{Lemieux.Tools.Read, :run, 2, [file: ~c"/home/private/code.ex", line: 42]}]}
      )

    error = Entry.new(:error, %{"reason" => "private", "diagnostic" => diagnostic}, seq: 2)

    summary =
      Entry.new(
        :extension_state,
        %{
          "namespace" => "lemieux.errors",
          "value" => %{"count" => 1, "error_ids" => [diagnostic["id"]]}
        },
        seq: 3
      )

    %{
      id: "session",
      entries: [Entry.new(:user, %{"text" => "unrelated private source"}), error, summary]
    }
  end

  test "exports only bounded safe provenance and reuses anchored bug feedback", ctx do
    store = JSONL.new(Path.join(ctx.tmp_dir, "feedback"))
    opts = [feedback_store: store, bug_reports_dir: Path.join(ctx.tmp_dir, "reports")]
    snapshot = snapshot()

    assert {:ok, report} =
             BugReport.prepare(snapshot, "The agent recovered but I missed the error", opts)

    assert File.read!(report.path) == report.body
    assert report.body =~ "Lemieux.Tools.Read"
    refute report.body =~ "sk-test123"
    refute report.body =~ "/home/private"
    refute report.body =~ "unrelated private source"
    refute report.body =~ "private text"
    assert {:ok, record} = Store.latest(store, report.feedback_id)
    assert record.type == :bug
    assert record.provenance["entry_id"] == Enum.at(snapshot.entries, 1).id
    assert {:ok, stat} = File.stat(report.path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "edits require a fresh sanitized preview; only a subsequent explicit submit calls GitHub",
       ctx do
    opts = [
      feedback_store: JSONL.new(Path.join(ctx.tmp_dir, "feedback")),
      bug_reports_dir: ctx.tmp_dir
    ]

    {:ok, report} = BugReport.prepare(snapshot(), "A bug", opts)
    File.write!(report.path, report.body <> "\nauthorization: Bearer sensitive\n")
    parent = self()

    submit = fn body ->
      send(parent, {:submitted, body})
      {:ok, "issue URL"}
    end

    assert {:preview, reviewed} = BugReport.submit(report, submit: submit)
    refute_receive {:submitted, _}, 20
    refute reviewed.body =~ "sensitive"
    assert {:ok, "issue URL"} = BugReport.submit(reviewed, submit: submit)
    assert_receive {:submitted, body}
    assert body == reviewed.body

    assert {:error, _reason} =
             BugReport.submit(reviewed, submit: fn _ -> {:error, :unavailable} end)

    assert File.exists?(reviewed.path)
  end

  test "sanitizes user-supplied credentials, identifiers, paths, links and terminal controls" do
    input =
      "api_key=private\n\"account_id\":\"org-private\"\n/another/private/workspace/file\nC:\\Users\\private\\file\nBearer token123\nsk-example\nuser@example.test\nhttps://private.example/query?token=foo\n\e]52;c;bad\a"

    output = BugReport.sanitize(input)

    for private <- [
          "org-private",
          "workspace",
          "Users",
          "token123",
          "sk-example",
          "example.test",
          "private.example",
          "\e"
        ] do
      refute output =~ private
    end
  end

  test "ordinary feedback stays available and bug submission needs a prepared report" do
    conversation = Conversation.new(model: "test:model")
    assert [{:bug_report, "", nil}] = Feedback.parse("bug", conversation)

    assert [{:bug_report, "description", 3}] =
             Feedback.parse("bug turn 3 description", conversation)

    assert [{:say, _}] = Feedback.parse("bug submit", conversation)

    assert {%{feedback: {:pending, "ordinary"}}, [:feedback]} =
             Feedback.parse("ordinary", conversation)

    assert [{:say, _}] = Feedback.parse("bug", %{conversation | busy?: true})
    assert {:error, _} = BugReport.prepare(%{id: "empty", entries: []}, "", [])
  end
end
