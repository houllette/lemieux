defmodule Lemieux.TUI.EffectsTest do
  @moduledoc """
  The effects the screen performs differently from other hosts: `/help`'s key
  table and `/resume`'s listing, and the host fields it hands the shared
  dispatcher.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.CLI.SessionIndex
  alias Lemieux.TUI.Effects
  alias Lemieux.TUI.Keys

  defp perform(state, effect) do
    assert {:noreply, state} = Effects.run(state, [effect])
    state
  end

  # What the screen said, oldest first, as one text: the rows `Transcript.say`
  # stored, rather than a rendered frame that a long listing would scroll.
  defp lmx_text(state) do
    state.lines
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:lmx, text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp position(text, part) do
    case :binary.match(text, part) do
      {start, _length} -> start
      :nomatch -> flunk("#{inspect(part)} is not in:\n#{text}")
    end
  end

  defp sessions do
    now = DateTime.utc_now()

    [
      %SessionIndex{
        id: "01OLDHERE",
        shorthand: "old-here",
        at: DateTime.add(now, -5 * 86_400),
        updated_at: DateTime.add(now, -3 * 86_400),
        cwd: "/work/here",
        model: "test:model",
        preview: "fix the flaky tests"
      },
      %SessionIndex{
        id: "01NEWHERE",
        shorthand: "new-here",
        at: DateTime.add(now, -86_400),
        updated_at: DateTime.add(now, -120),
        cwd: "/work/here",
        preview: "add a --cwd flag"
      },
      %SessionIndex{
        id: "01ELSEWHERE",
        shorthand: "elsewhere",
        at: DateTime.add(now, -60),
        updated_at: DateTime.add(now, -60),
        cwd: "/work/other",
        preview: "another repository"
      }
    ]
  end

  describe "/resume" do
    test "opens this folder and switches scope without losing the search" do
      state = tui(sessions: sessions(), cwd: "/work/here") |> command("/resume")
      text = screen(state)
      assert state.modal.scope == :here
      assert text =~ "This folder"
      assert position(text, "new-here") < position(text, "old-here")
      assert text =~ "2m ago"
      assert text =~ "add a --cwd flag"
      refute text =~ "another repository"

      searched = type(state, "repo")
      assert screen(searched) =~ "No matching sessions"
      all = press(searched, "tab")
      assert all.modal.scope == :all
      assert screen(all) =~ "/work/other"
      refute screen(all) =~ "new-here"
      back = press(all, "back_tab", ["shift"])
      assert back.modal.scope == :here
      assert back.modal.query == "repo"
      assert press(back, "esc").modal == nil
    end

    test "all shows directory context and sorts by last activity" do
      state = tui(sessions: sessions(), cwd: "/work/here") |> command("/resume all")
      assert state.modal.scope == :all
      text = screen(state)
      assert position(text, "elsewhere") < position(text, "new-here")
    end

    test "unknown directories stay reachable from the empty folder tab" do
      unknown = Enum.map(sessions(), &%{&1 | cwd: nil})
      state = tui(sessions: unknown, cwd: "/work/here") |> perform(:resume_status)

      assert screen(state) =~ "No previous sessions in this folder"
      all = press(state, "tab")
      assert screen(all) =~ "elsewhere"
      assert screen(all) =~ "directory unknown"
    end

    test "leaves out the session on screen and compares normalized paths" do
      text =
        tui(sessions: sessions(), cwd: "/work/here/../here", id: "01NEWHERE")
        |> perform(:resume_status)
        |> screen()

      refute text =~ "new-here"
      assert text =~ "old-here"
    end

    test "loads and scrolls the full index, then resumes the selected ID" do
      owner = self()
      [entry | _] = sessions()

      many =
        for n <- 1..80 do
          %{
            entry
            | id: "SESSION-#{n}",
              shorthand: "shared name",
              updated_at: DateTime.add(entry.at, -n)
          }
        end

      start = fn id, _subscriber ->
        send(owner, {:selected, id})
        {:error, :already_open}
      end

      list = fn -> {:ok, many ++ [hd(many)]} end
      state = tui(cwd: entry.cwd, resume_session: start)
      state = put_in(state.resume.list_all, list)
      opened = command(state, "/resume")
      assert_receive {:resume_picker_index, _, _} = loaded
      assert {:noreply, ready} = Lemieux.TUI.handle_info(loaded, opened)
      assert length(ready.modal.matches) == 80
      scrolled = Enum.reduce(1..70, ready, fn _, ui -> press(ui, "down") end)
      assert screen(scrolled) =~ "71/80"
      assert press(scrolled, "enter").modal == nil
      assert_receive {:selected, "SESSION-71"}
      assert_receive {:resume_result, "SESSION-71", {:error, :already_open}}

      busy = put_in(ready.conversation.busy?, true)
      assert screen(press(busy, "enter")) =~ "cancel or wait for this turn"
      refute_received {:selected, _}
    end
  end

  describe "/help" do
    test "lists the key bindings after the commands" do
      text = tui() |> command("/help") |> lmx_text()

      assert position(text, "/model") < position(text, "Keys")
      assert text =~ ~r/ctrl-c\s+cancel the turn/
      assert text =~ ~r/!command\s+run a shell command/
    end

    # The configured table, so a remapped key is listed where it now is.
    test "lists a remapped key where the host put it" do
      keys = Keys.from_map!(%{"ctrl-x" => "interrupt"})
      text = tui(keys: keys) |> command("/help") |> lmx_text()

      assert text =~ ~r/ctrl-c, ctrl-x\s+cancel the turn|ctrl-x, ctrl-c\s+cancel the turn/
    end
  end
end
