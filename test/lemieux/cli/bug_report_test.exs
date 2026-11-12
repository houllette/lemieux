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

    assert {%{bug_report: %{phase: :preparing}}, [{:bug_report, "", nil}]} =
             Feedback.parse("bug", conversation)

    assert {%{bug_report: %{phase: :preparing}}, [{:bug_report, "description", 3}]} =
             Feedback.parse("bug turn 3 description", conversation)

    assert [{:say, _}] = Feedback.parse("bug submit", conversation)

    assert {%{feedback: {:pending, "ordinary"}}, [:feedback]} =
             Feedback.parse("ordinary", conversation)

    assert [{:say, _}] = Feedback.parse("bug", %{conversation | busy?: true})
    assert {:error, _} = BugReport.prepare(%{id: "empty", entries: []}, "", [])
  end

  test "submission is single-flight and failure keeps the reviewed draft retryable" do
    conversation = Conversation.new(model: "test:model")
    report = %{path: "draft", body: "reviewed", sha256: "digest"}
    {reviewed, _} = Conversation.event(conversation, {:bug_report_result, {:ok, report}})
    {submitting, [{:bug_submit, outgoing}]} = Feedback.parse("bug submit", reviewed)
    assert outgoing.body == "reviewed"
    assert [{:say, _}] = Feedback.parse("bug submit", submitting)
    {retryable, _} = Conversation.event(submitting, {:bug_submit_result, {:error, "unavailable"}})
    assert retryable.bug_report.phase == :reviewed
    assert {%{}, [{:bug_submit, _}]} = Feedback.parse("bug submit", retryable)
  end

  test "bounded Unicode drafts still export when the feedback ledger cannot be written", ctx do
    blocked = Path.join(ctx.tmp_dir, "blocked")
    File.write!(blocked, "file instead of directory")

    {:ok, report} =
      BugReport.prepare(snapshot(), String.duplicate("🦆", 20_000),
        feedback_store: JSONL.new(blocked),
        bug_reports_dir: ctx.tmp_dir
      )

    assert byte_size(report.body) <= 16_384
    assert String.valid?(report.body)
    assert report.feedback_id == nil
    assert report.notice =~ "draft export remains available"
    assert File.read!(report.path) == report.body
  end

  test "GitHub CLI receives a private frozen body file and no interactive prompt", ctx do
    executable = Path.join(ctx.tmp_dir, "github fixture")

    File.write!(executable, """
    #!/usr/bin/env python3
    import os, sys, stat
    assert sys.argv[1:3] == ['issue', 'create']
    assert sys.argv[sys.argv.index('--repo') + 1] == 'houllette/lemieux'
    assert os.environ['GH_PROMPT_DISABLED'] == '1'
    path = sys.argv[sys.argv.index('--body-file') + 1]
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert 'Diagnostics' in open(path).read()
    print('https://github.com/houllette/lemieux/issues/999')
    """)

    File.chmod!(executable, 0o700)

    {:ok, report} =
      BugReport.prepare(snapshot(), "A bug",
        feedback_store: JSONL.new(Path.join(ctx.tmp_dir, "feedback")),
        bug_reports_dir: ctx.tmp_dir
      )

    assert {:ok, "https://github.com/houllette/lemieux/issues/999"} =
             BugReport.submit(report, github_command: executable)

    assert File.exists?(report.path)
  end
end
