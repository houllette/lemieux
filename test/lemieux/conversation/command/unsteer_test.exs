defmodule Lemieux.Conversation.Command.UnsteerTest do
  @moduledoc """
  `/unsteer` as a front end other than the screen performs it: the session's
  newest waiting steer, revoked through `Lemieux.Session.revoke_steer/2`.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Command.Unsteer
  alias Lemieux.Conversation.Dispatch

  # Answers `info/2` with the steers it holds and `revoke_steer/2` the way
  # the session does: `:ok` for one it still holds, `:already_sent` otherwise.
  defp session(steers), do: spawn_link(fn -> loop(steers) end)

  defp loop(steers) do
    receive do
      {:"$gen_call", from, :info} ->
        GenServer.reply(from, %{queued_steers: steers})
        loop(steers)

      {:"$gen_call", from, {:revoke_steer, text}} ->
        if text in steers do
          GenServer.reply(from, :ok)
          loop(List.delete(steers, text))
        else
          GenServer.reply(from, {:error, :already_sent})
          loop(steers)
        end
    end
  end

  defp host(session) do
    Dispatch.new(
      session: session,
      say: fn said, text -> [text | said] end,
      write: fn said, _text -> said end,
      fold: fn said, _event -> said end,
      run: fn said, _work -> said end,
      react: fn said, _reaction -> said end
    )
  end

  test "is a built-in that parses to its one action, mid-turn or not" do
    conversation = Conversation.new()

    assert Unsteer in Builtin.all()
    assert Unsteer.parse("", conversation) == [:unsteer]
    assert Unsteer.parse("", %{conversation | busy?: true}) == [:unsteer]
  end

  test "revokes the newest steer the session still holds" do
    session = session(["first", "second"])

    assert Dispatch.perform([], host(session), :unsteer) == [
             "steer revoked before the next model request"
           ]

    assert %{queued_steers: ["first"]} = GenServer.call(session, :info)
  end

  test "says so when there is nothing to take back" do
    assert Dispatch.perform([], host(session([])), :unsteer) == ["no steer is waiting"]
    assert Dispatch.perform([], host(nil), :unsteer) == ["no steer is waiting"]
  end
end
