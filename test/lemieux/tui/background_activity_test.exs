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
              "background" => true,
              "summary" => "Background analysis #{n}"
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
            "structured_content" => %{
              "task_id" => "task-#{n}",
              "task_name" => "player-#{n}",
              "summary" => "Background analysis #{n}",
              "status" => "running"
            },
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

    state =
      Enum.reduce(
        Enum.reverse(launch_results),
        state,
        &info(&2, {:entry, Entry.new(:tool_result, &1)})
      )

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

      assert Enum.count(rows, &match?({:tool_task, _, _, _, "running"}, &1)) == 3

      assert for({:tool_task, _, name, _, _} <- rows, do: name) == [
               "player-1",
               "player-2",
               "player-3"
             ]

      text =
        rows
        |> RichText.lines(160)
        |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

      for n <- 1..3, do: assert(text =~ "player-#{n} Running — Background analysis #{n}")
      refute text =~ "printf"
      refute text =~ "sleep 30"
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

  test "completion cards separate the player, outcome and summary with theme-aware emphasis" do
    card =
      {:background_result,
       %{
         "name" => "wayne-gretzky",
         "status" => "Completed",
         "summary" => "Watch a 45-second timer with progress updates",
         "elapsed" => "45s"
       }}

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()], width <- [20, 80] do
      lines = RichText.lines([card], width, theme)
      assert length(lines) >= 3
      text = Enum.map_join(lines, " ", fn line -> Enum.map_join(line.spans, & &1.content) end)
      assert text =~ "wayne-gretzky"
      assert text =~ "Completed"
      assert text =~ "45s"
      assert text =~ "F6 Tasks"
      refute text =~ "printf"
      styles = for line <- lines, span <- line.spans, do: span.style
      assert length(Enum.uniq(styles)) > 1
    end
  end

  test "completion updates earlier task status live and after resume" do
    call = %{
      id: "launch",
      name: "bash",
      arguments: %{"background" => true, "command" => "sleep 45", "summary" => "Observe a timer"}
    }

    payload = %{
      "call_id" => "launch",
      "name" => "bash",
      "structured_content" => %{
        "task_id" => "internal",
        "task_name" => "wayne-gretzky",
        "summary" => "Observe a timer",
        "status" => "running"
      }
    }

    card = %{
      "name" => "wayne-gretzky",
      "status" => "Completed",
      "summary" => "Observe a timer",
      "elapsed" => "45s"
    }

    receipt =
      Entry.new(:extension_state, %{
        "namespace" => "lemieux.notification",
        "value" => %{"id" => "finished", "background_results" => [card], "text" => "Completed"}
      })

    state =
      tui()
      |> info({:tool_call, call})
      |> info({:entry, Entry.new(:tool_result, payload)})
      |> info({:entry, receipt})

    resumed =
      TranscriptPresentation.lines(
        [assistant([call]), Entry.new(:tool_result, payload), receipt],
        %{theme: Theme.dark(), renderers: Renderer.builtin(), width: 80}
      )

    for rows <- [state.lines, resumed] do
      assert {:tool_task, "launch", "wayne-gretzky", "Observe a timer", "completed"} in rows
      refute Enum.any?(rows, &match?({:tool_task, _, _, _, "running"}, &1))
    end
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
