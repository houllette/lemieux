defmodule Lemieux.TUI.ToolPresentationTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Entry
  alias Lemieux.TUI
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText
  alias Lemieux.TUI.TranscriptPresentation

  @tasks [
    %{"id" => "t1", "title" => "Inspect runtime", "status" => "completed"},
    %{"id" => "t2", "title" => "Improve the transcript", "status" => "in_progress"},
    %{"id" => "t3", "title" => "Validate changes", "status" => "pending"}
  ]

  test "todo receipts show the revision, progress and colored statuses without action scaffolding" do
    call = %{id: "todo-1", name: "todo", arguments: %{"action" => "set"}}
    payload = todo_result(call.id, 2, @tasks).payload
    assert {:replace, rows} = ToolText.result(call, payload, Theme.dark())
    assert Renderer.check_rows(rows, call.id) == :ok
    text = rendered(rows, Theme.dark())
    assert text =~ "Todo List: revision 2 · 1/3 complete"
    assert text =~ "✓ Completed"
    assert text =~ "◐ In progress"
    assert text =~ "○ Pending"
    refute text =~ "Ran todo"
    refute text =~ "└ set"
    refute text =~ "t1 [completed]"

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      spans = rows |> RichText.lines(80, theme) |> Enum.flat_map(& &1.spans)
      assert Enum.any?(spans, &(&1.content =~ "Completed" and &1.style.fg == theme.children.ok))

      assert Enum.any?(
               spans,
               &(&1.content =~ "In progress" and &1.style.fg == theme.voices.activity)
             )

      assert Enum.any?(spans, &(&1.content =~ "Pending" and &1.style.fg == theme.children.warn))
    end
  end

  test "todo status rows wrap long titles and historical text-only receipts remain readable" do
    call = %{id: "todo-1", name: "todo", arguments: %{"action" => "list"}}
    title = "Inspect runtime, TUI, and test paths for concrete efficiency opportunities"
    payload = %{"output" => "Plan revision 2\nt1 [in_progress] #{title}", "error" => false}
    assert {:replace, rows} = ToolText.result(call, payload, Theme.dark())
    text = rendered(rows, Theme.dark(), 32)
    assert text =~ "revision 2"
    assert text =~ "In progress"
    assert text =~ "opportunities"
    refute text =~ "clipped"
  end

  test "the todo panel persists through replies and restores its revision until completion" do
    entry = plan_entry(2, @tasks)
    live = tui() |> info({:entry, entry}) |> info({:text_delta, "Still working."})
    assert screen(live) =~ "Todo List · revision 2 · 1/3 complete"
    assert screen(live) =~ "In progress"
    session = fake_session(snapshot("restored", [entry]))
    assert {:ok, restored} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert screen(restored) =~ "Todo List · revision 2 · 1/3 complete"

    done = Enum.map(@tasks, &Map.put(&1, "status", "completed"))
    completed = info(live, {:entry, plan_entry(3, done)})
    refute screen(completed) =~ "Todo List ·"
  end

  test "subagents have a readable footer and keep the JSON in the pager on live and restored paths" do
    for name <- ["delegate", "subagents"] do
      call = %{id: "scout-1", name: name, arguments: %{"tasks" => []}}
      group = %{"status" => "ok", "results" => [%{"child_id" => "child", "answer" => "Findings"}]}
      output = JSON.encode!(Map.put(group, "group_id", "opaque-group-id"))

      result =
        Entry.new(:tool_result, %{"call_id" => call.id, "name" => name, "output" => output})

      live =
        tui()
        |> info({:tool_call, call})
        |> info({:subagent, ["root"], {:group_finished, group}})
        |> info({:entry, result})

      text = screen(live)
      assert text =~ "Subagents:"
      assert text =~ "Subagents complete · 1 read-only investigation"
      refute text =~ "Ran #{name}"
      refute text =~ "── delegation"
      refute text =~ "opaque-group-id"
      assert screen(press(live, "o", ["ctrl"])) =~ "opaque-group-id"

      entries = [
        Entry.new(:assistant, %{
          "tool_calls" => [%{"id" => call.id, "name" => name, "arguments" => call.arguments}]
        }),
        Entry.new(:subagent_group_result, group),
        result
      ]

      rows =
        TranscriptPresentation.lines(entries, %{
          theme: Theme.dark(),
          renderers: Renderer.builtin(),
          width: 80
        })

      assert rendered(rows, Theme.dark()) =~ "Subagents complete · 1 read-only investigation"
      refute rendered(rows, Theme.dark()) =~ "opaque-group-id"
    end
  end

  test "failed and unfamiliar subagent results remain visible" do
    call = %{id: "scout-1", name: "subagents", arguments: %{}}

    assert ToolText.result(call, %{"error" => true, "output" => "request failed"}, Theme.dark()) ==
             {:output, "request failed"}

    assert ToolText.result(call, %{"output" => "unfamiliar result"}, Theme.dark()) ==
             {:output, "unfamiliar result"}
  end

  test "live and restored spacing separates calls, keeps exploration grouped and survives repeated results" do
    first = %{id: "bash-1", name: "bash", arguments: %{"command" => "mix test"}}
    second = %{id: "bash-2", name: "bash", arguments: %{"command" => "mix format"}}

    result = fn call ->
      Entry.new(:tool_result, %{"call_id" => call.id, "name" => call.name, "output" => "ok"})
    end

    recorded = fn call ->
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [%{"id" => call.id, "name" => call.name, "arguments" => call.arguments}]
      })
    end

    user = Entry.new(:user, %{"text" => "Check this"})

    reads =
      for n <- 1..2, do: %{id: "read-#{n}", name: "read", arguments: %{"path" => "file#{n}.ex"}}

    entries =
      [user, recorded.(first), result.(first), recorded.(second), result.(second)] ++
        Enum.flat_map(reads, &[recorded.(&1), result.(&1)]) ++
        [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "Done."}]})]

    live = tui(lines: [{:you, "Check this"}])

    live =
      Enum.reduce([first, second] ++ reads, live, fn call, state ->
        state
        |> info({:tool_call, call})
        |> info({:entry, result.(call)})
        |> info({:entry, result.(call)})
      end)

    live = info(live, {:text_delta, "Done."})

    rows =
      TranscriptPresentation.lines(entries, %{
        theme: Theme.dark(),
        renderers: Renderer.builtin(),
        width: 80
      })

    assert Enum.reverse(live.lines) == rows
    assert Enum.count(rows, &(&1 == {:space, ""})) == 4
    assert Enum.count(rows, &match?({:tool_heading, _, :explore, _, _}, &1)) == 1
    text = rendered(rows, Theme.dark())
    assert text =~ "mix test\n  └ ok\n\n• Ran mix format"
    assert text =~ "Read file1.ex\n└ Read file2.ex"
    assert text =~ "Read file2.ex\n\nDone."
  end

  defp todo_result(id, revision, tasks) do
    Entry.new(:tool_result, %{
      "call_id" => id,
      "name" => "todo",
      "output" => "Plan revision #{revision}",
      "structured_content" => %{"revision" => revision, "plan" => %{"tasks" => tasks}}
    })
  end

  defp plan_entry(revision, tasks),
    do:
      Entry.new(:extension_state, %{
        "namespace" => "lemieux.plan",
        "revision" => revision,
        "value" => %{"tasks" => tasks}
      })

  defp rendered(rows, theme, width \\ 80),
    do:
      rows
      |> RichText.lines(width, theme)
      |> Enum.map_join("\n", &Enum.map_join(&1.spans, fn span -> span.content end))
end
