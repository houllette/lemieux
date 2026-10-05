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

  # Performed directly: typing `/resume` and Enter takes the highlighted
  # session out of the completion menu the command opens, which is the menu's
  # job and not what these tests are about.
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
    test "lists this directory's sessions, most recently active first" do
      text = tui(sessions: sessions(), cwd: "/work/here") |> perform(:resume_status) |> lmx_text()

      assert text =~ "sessions in this directory, most recent first"
      assert position(text, "new-here") < position(text, "old-here")
      assert text =~ "2m ago"
      assert text =~ "\"add a --cwd flag\""
      refute text =~ "another repository"
      assert text =~ "/resume all adds 1 from other directories"
    end

    test "all lists every directory's" do
      text =
        tui(sessions: sessions(), cwd: "/work/here")
        |> perform({:resume_list, :all})
        |> lmx_text()

      assert text =~ "stored sessions, most recent first"
      assert position(text, "elsewhere") < position(text, "new-here")
    end

    test "a directory with none of its own points at the others" do
      text =
        tui(sessions: sessions(), cwd: "/work/empty") |> perform(:resume_status) |> lmx_text()

      assert text =~ "no stored sessions in this directory · /resume all lists 3"
    end

    # An index built before sessions recorded their directory: listing
    # everything beats claiming there is nothing here.
    test "an index that does not know directories lists everything" do
      unknown = Enum.map(sessions(), &%{&1 | cwd: nil})
      text = tui(sessions: unknown, cwd: "/work/here") |> perform(:resume_status) |> lmx_text()

      assert text =~ "stored sessions"
      assert text =~ "elsewhere"
    end

    test "leaves out the session on screen" do
      text =
        tui(sessions: sessions(), cwd: "/work/here", id: "01NEWHERE")
        |> perform(:resume_status)
        |> lmx_text()

      refute text =~ "new-here"
      assert text =~ "old-here"
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
