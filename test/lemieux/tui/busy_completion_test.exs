defmodule Lemieux.TUI.BusyCompletionTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  for busy? <- [false, true] do
    test "Enter accepts the highlighted argument with busy=#{busy?}" do
      state = tui(theme: "dark")
      state = put_in(state.conversation.busy?, not unquote(busy?))
      state = state |> type("/theme ") |> press("down")
      assert suggestions(state).selected == 1
      assert Enum.at(suggestions(state).items, 1) == "light"
      state = put_in(state.conversation.busy?, unquote(busy?))
      submitted = press(state, "enter")
      assert hd(submitted.history.entries) == "/theme light"
      assert submitted.appearance.theme.name == "light"
      assert typed(submitted) == ""
    end

    test "partial arguments and command names complete with busy=#{busy?}" do
      state = tui(theme: "dark") |> type("/theme l")
      state = put_in(state.conversation.busy?, unquote(busy?))
      assert press(state, "enter").appearance.theme.name == "light"

      state = tui() |> type("/hel")
      state = put_in(state.conversation.busy?, unquote(busy?))
      assert hd(press(state, "enter").history.entries) == "/help"

      state = tui(models: ["test:one"]) |> type("/mo")
      state = put_in(state.conversation.busy?, unquote(busy?))
      opened = press(state, "enter")
      assert typed(opened) == "/model "
      assert suggestions(opened).items == ["one"]
      assert opened.history.queued == []
    end
  end

  test "Tab takes visible completion during work before queueing an ordinary draft" do
    state = tui(theme: "dark") |> type("/theme l")
    state = put_in(state.conversation.busy?, true)
    completed = press(state, "tab")
    assert typed(completed) == "/theme light"
    assert completed.history.queued == []
    assert completed.appearance.theme.name == "dark"

    :ok = ExRatatui.textarea_set_value(completed.input, "follow up later")
    queued = press(completed, "tab")
    assert typed(queued) == ""
    assert length(queued.history.queued) == 1
  end

  @tag :tmp_dir
  test "file choices fill the active draft and ordinary Enter still steers", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "README.md"), "read me")
    session = fake_session(snapshot("01SESSION"))
    state = tui(cwd: cwd, session: session)
    state = put_in(state.conversation.busy?, true)
    state = state |> type("explain @RE") |> press("enter")
    assert typed(state) == "explain @README.md "
    assert state.history.entries == []
    assert state.history.queued == []

    :ok = ExRatatui.textarea_set_value(state.input, "please check the tests")
    sent = press(state, "enter")
    assert typed(sent) == ""
    assert_receive {:steered, "please check the tests"}
  end
end
