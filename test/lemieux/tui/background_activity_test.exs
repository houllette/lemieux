defmodule Lemieux.TUI.BackgroundActivityTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias Lemieux.Entry
  alias Lemieux.TUI.{Renderer, RichText, Theme, ToolText, TranscriptPresentation}

  test "parallel launches and redundant watch registrations have one compact live and resumed group" do
    calls =
      for n <- 1..3,
          do: %{
            id: "launch-#{n}",
            name: "bash",
            arguments: %{
              "command" => "printf 'demo-#{n} started'; sleep 30",
              "background" => true
            }
          }

    watches =
      for n <- 1..3,
          do: %{
            id: "watch-#{n}",
            name: "watch",
            arguments: %{
              "action" => "register",
              "source" => "background",
              "target" => %{"task_id" => "task-#{n}"}
            }
          }

    launch_results =
      for n <- 1..3,
          do: %{
            "call_id" => "launch-#{n}",
            "name" => "bash",
            "output" =>
              "Background task task-#{n} started. Continue independent work and yield instead of polling.",
            "structured_content" => %{"task_id" => "task-#{n}", "status" => "running"},
            "error" => false
          }

    watch_results =
      for n <- 1..3,
          do: %{
            "call_id" => "watch-#{n}",
            "name" => "watch",
            "output" => "registered",
            "error" => false
          }

    entries =
      [assistant(calls)] ++
        Enum.map(launch_results, &Entry.new(:tool_result, &1)) ++
        [assistant(watches)] ++ Enum.map(watch_results, &Entry.new(:tool_result, &1))

    state = Enum.reduce(calls, tui(), &info(&2, {:tool_call, &1}))
    state = Enum.reduce(launch_results, state, &info(&2, {:entry, Entry.new(:tool_result, &1)}))
    state = Enum.reduce(watches, state, &info(&2, {:tool_call, &1}))
    state = Enum.reduce(watch_results, state, &info(&2, {:entry, Entry.new(:tool_result, &1)}))

    resumed =
      TranscriptPresentation.lines(entries, %{
        theme: Theme.dark(),
        renderers: Renderer.builtin(),
        width: 160
      })

    for rows <- [Enum.reverse(state.lines), resumed] do
      assert Enum.count(
               rows,
               &match?({:tool_heading, nil, :background, "Background tasks:", ""}, &1)
             ) == 1

      assert Enum.count(rows, &match?({:tool_detail, _, :background, _}, &1)) == 3

      text =
        rows
        |> RichText.lines(160)
        |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

      for n <- 1..3, do: assert(text =~ "└ Ran printf 'demo-#{n} started'; sleep 30")
      refute text =~ "register"
      refute text =~ "task-"
      refute text =~ "yield instead of polling"
      refute text =~ "Ran watch"
    end
  end

  test "failed tracking stays visible with context, and foreground commands retain output" do
    call = %{
      id: "watch",
      name: "watch",
      arguments: %{"action" => "register", "source" => "background"}
    }

    assert ToolText.call(call) == []

    assert {:output, "Watch register failed: command not found"} =
             ToolText.result(
               call,
               %{"error" => true, "output" => "command not found"},
               Theme.dark()
             )

    assert {:output, "READY"} =
             ToolText.result(
               %{id: "fg", name: "bash", arguments: %{"command" => "printf READY"}},
               %{"output" => "READY"},
               Theme.dark()
             )
  end

  test "a foreground action or answer separates background groups" do
    first = ToolText.background("one", "Ran first")

    assert ToolText.join_background(ToolText.background("two", "Ran second"), List.last(first)) ==
             [{:tool_detail, "two", :background, "Ran second"}]

    assert length(ToolText.join_background(first, {:model, "Next task"})) == 2
  end

  test "a launched command still exposes an automatic tracking failure" do
    call = %{id: "launch", name: "bash", arguments: %{"command" => "build", "background" => true}}

    assert {:output, "Tracking unavailable: disconnected · Tasks (F6)"} =
             ToolText.result(
               call,
               %{
                 "structured_content" => %{
                   "task_id" => "task",
                   "status" => "running",
                   "background_tracking_error" => "disconnected"
                 }
               },
               Theme.dark()
             )
  end

  test "tracking arguments cannot crash presentation before tool validation" do
    assert ToolText.call(%{
             id: "bad",
             name: "watch",
             arguments: %{"action" => "register", "source" => "github", "target" => "invalid"}
           }) == []

    rows =
      ToolText.call(%{
        id: "bad-value",
        name: "watch",
        arguments: %{
          "action" => "register",
          "source" => "github",
          "target" => %{"run_id" => %{"invalid" => true}}
        }
      })

    assert ToolText.announced?(rows, "bad-value")

    assert {:output, text} =
             ToolText.result(
               %{id: "bad-action", name: "watch", arguments: %{"action" => %{}}},
               %{"error" => true, "output" => "Invalid action"},
               Theme.dark()
             )

    assert text =~ "Invalid action"
  end

  defp assistant(calls),
    do:
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" =>
          Enum.map(calls, fn call ->
            %{"id" => call.id, "name" => call.name, "arguments" => call.arguments}
          end)
      })
end
