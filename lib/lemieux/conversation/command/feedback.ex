defmodule Lemieux.Conversation.Command.Feedback do
  @moduledoc """
  `/feedback [TEXT]`: opens the capture dialogue `Lemieux.Feedback.Dialogue` owns.

  Refused mid-turn for the reason `/reflect` is, and for one more: while a
  turn runs a typed line is a steer, and a dialogue that took those lines
  would have somebody typing a correction into a feedback form.

  The parse only notes that anchors are wanted; `perform/3` reads them from
  the session, because only a host holds one, and hands them back as
  `{:feedback_anchors, anchors}` for `Lemieux.Conversation.event/2` to open
  the dialogue with. The write at the end, `{:feedback, submission}`, is not
  a command — the dialogue produces it — and stays in
  `Lemieux.Conversation.Dispatch`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "feedback",
      description: "record what should have gone differently",
      accepts_arguments?: true,
      action: :feedback,
      actions: [{:bug_report, "", nil}, {:bug_submit, %{}}],
      subcommands: ["bug", "bug submit"]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("bug submit", %Conversation{bug_report: report}) when is_map(report),
    do: [{:bug_submit, report}]

  def parse("bug submit", _conversation), do: [{:say, "prepare and review /feedback bug first"}]

  def parse("bug" <> rest, conversation) when rest == "" or binary_part(rest, 0, 1) == " " do
    if conversation.busy? do
      [{:say, "wait for the turn before preparing its bug report"}]
    else
      case Regex.run(~r/^\s+turn\s+(\d+)(?:\s+(.*))?$/s, rest) do
        [_, seq, text] -> [{:bug_report, text, String.to_integer(seq)}]
        [_, seq] -> [{:bug_report, "", String.to_integer(seq)}]
        _text -> [{:bug_report, String.trim(rest), nil}]
      end
    end
  end

  def parse(_text, %Conversation{busy?: true}),
    do: [{:say, "wait for it to finish, or /cancel before capturing feedback"}]

  def parse(text, conversation),
    do: {%{conversation | feedback: {:pending, String.trim(text)}}, [:feedback]}

  @impl Lemieux.Conversation.Command
  def perform(acc, %{feedback: nil} = host, _effect),
    do: Dispatch.say(acc, host, "this host does not support feedback reporting")

  def perform(acc, host, {:bug_report, text, seq}) do
    Dispatch.run(acc, host, fn ->
      opts = Keyword.put(host.feedback_opts, :turn_seq, seq)

      {:bug_report_result,
       host.feedback.prepare_bug_report(Session.snapshot(host.session), text, opts)}
    end)
  end

  def perform(acc, host, {:bug_submit, report}) do
    Dispatch.run(acc, host, fn ->
      {:bug_submit_result, host.feedback.submit_bug_report(report, host.feedback_opts)}
    end)
  end

  def perform(acc, host, :feedback) do
    %{session: session, feedback: feedback} = host

    Dispatch.run(acc, host, fn ->
      {:feedback_anchors, feedback.anchors(Session.snapshot(session))}
    end)
  end
end
