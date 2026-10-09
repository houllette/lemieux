defmodule Lemieux.TUI.DiffPanelTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias ExRatatui.Event.Resize
  alias ExRatatui.Frame
  alias Lemieux.Conversation.Command.Diff
  alias Lemieux.TUI
  alias Lemieux.TUI.DiffPanel
  @moduletag :tmp_dir

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp repository(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), "before\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-qm", "initial"])
    dir
  end

  test "status retains rename pairs and unusual filenames; previews use literal root paths", %{
    tmp_dir: dir
  } do
    repository(dir)
    git!(dir, ["mv", "lib/a.ex", "lib/b.ex"])
    File.write!(Path.join(dir, "lib/b.ex"), "before\nafter\n")
    strange = ":(glob)'$()\nnew.txt"
    File.write!(Path.join(dir, strange), "fresh\n")
    environment = Lemieux.Environment.local()
    assert {:ok, %{files: files, omitted: 0}} = Diff.files(environment, Path.join(dir, "lib"))
    renamed = Enum.find(files, &(&1.path == "lib/b.ex"))
    assert renamed.previous == "lib/a.ex"
    assert {:ok, patch} = Diff.preview(environment, Path.join(dir, "lib"), renamed)
    assert patch =~ "+after"
    fresh = Enum.find(files, &(&1.path == strange))
    assert fresh.status == "??"
    assert {:ok, patch} = Diff.preview(environment, Path.join(dir, "lib"), fresh)
    assert patch =~ "+fresh"
    assert {:error, _reason} = Diff.preview(environment, dir, %{path: "../outside", status: "??"})
  end

  test "the command opens a navigable tree, preserves the draft, and rejects late replies", %{
    tmp_dir: dir
  } do
    repository(dir)
    File.write!(Path.join(dir, "lib/a.ex"), "after\n")
    tasks = start_supervised!({Task.Supervisor, []})
    state = TUI.new(cwd: dir, task_supervisor: tasks) |> sized() |> command("/diff")
    assert %{kind: :diff, token: token, loading?: true} = state.modal
    assert_receive {:diff_files, ^token, {:ok, _result}} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    assert state.modal.tree.options.walk == false
    refute Enum.any?(state.lines, &match?({:you, "/diff"}, &1))
    assert screen(state) =~ "a.ex"
    state = type(state, "") |> press("enter")
    assert state.modal.view == :preview
    pending = state.modal.pending
    assert_receive {:diff_preview, ^pending, {:ok, patch}} = preview
    assert patch =~ "+after"
    assert {:noreply, state} = TUI.handle_info(preview, state)
    assert screen(state) =~ "+after"
    state = press(state, "tab")
    assert state.modal.view == :tree
    state = press(state, "q") |> type("my draft")
    assert typed(state) == "my draft"
    assert DiffPanel.answer(state, reply) == state
    assert DiffPanel.answer(state, preview) == state
  end

  test "narrow and short panels stay inside the terminal; resize adjusts tree scrolling", %{
    tmp_dir: dir
  } do
    repository(dir)
    files = for i <- 1..40, do: %{path: "lib/測試#{i}.ex", status: " M"}
    state = tui(cwd: dir)
    token = make_ref()

    state = %{
      state
      | modal: %{
          kind: :diff,
          session: state.session,
          token: token,
          files: [],
          loading?: true,
          tree: nil,
          selected: nil,
          omitted: 0,
          view: :tree,
          preview: [],
          pending: nil,
          offset: 0,
          notice: "reading"
        }
    }

    state = DiffPanel.answer(state, {:diff_files, token, {:ok, %{files: files, omitted: 3}}})
    assert {:noreply, fallback} = DiffPanel.key(key("down"), put_in(state.modal.tree, nil))
    assert fallback.modal.selected == Enum.at(fallback.modal.files, 1).tree_path

    for {width, height} <- [{1, 1}, {20, 8}, {42, 17}, {100, 30}] do
      assert {:noreply, resized} = TUI.handle_event(%Resize{width: width, height: height}, state)
      assert resized.modal.tree.rows == max(min(height - 6, 100), 4)

      for {_widget, rect} <- DiffPanel.render(resized, TUI.Screen.panes(resized)) do
        assert rect.x >= 0 and rect.y >= 0
        assert rect.x + rect.width <= width
        assert rect.y + rect.height <= height
      end

      assert is_list(TUI.render(resized, %Frame{width: width, height: height}))
    end
  end
end
