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
      action: :feedback
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_text, %Conversation{busy?: true}),
    do: [{:say, "wait for it to finish, or /cancel before capturing feedback"}]

  def parse(text, conversation),
    do: {%{conversation | feedback: {:pending, String.trim(text)}}, [:feedback]}

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :feedback) do
    %{session: session, feedback: feedback} = host

    Dispatch.run(acc, host, fn ->
      {:feedback_anchors, feedback.anchors(Session.snapshot(session))}
    end)
  end
end
