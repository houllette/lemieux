defmodule Lemieux.TUI.ArtFeaturesTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI, as: AgentUI
  alias Lemieux.TUI
  alias Lemieux.TUI.{Art, Blocks, RichText, StartupAnimation, Theme, Width}
  import Lemieux.TUI.TestSupport

  test "startup customization is bounded data and can be disabled" do
    assert StartupAnimation.resolve(nil)["options"]["text"] == "GO HABS GO"
    assert StartupAnimation.resolve(false) == false

    assert StartupAnimation.resolve(%{"options" => %{"text" => "HELLO"}})["background"] ==
             "#192168"

    refute StartupAnimation.valid?(%{"piece" => "Elixir.File"})
    refute StartupAnimation.valid?(%{"duration_ms" => 60_000})
    refute StartupAnimation.valid?(%{"options" => %{"text" => "\e[2J"}})
  end

  test "progress is measured and has a readable narrow fallback" do
    row = Art.progress(42, "context")
    assert text(RichText.lines([row], 48, Theme.mono())) =~ "42"
    assert text(RichText.lines([row], 12, Theme.mono())) =~ "42.0%"
    refute text(RichText.lines([row], 48, Theme.mono())) =~ "fetching"
  end

  test "closed A2UI fences render; invalid and incomplete input shows compact diagnostics" do
    source =
      Enum.map_join(
        [
          %{
            "version" => "v0.9.1",
            "createSurface" => %{
              "surfaceId" => "test",
              "catalogId" => AgentUI.catalog_id()
            }
          },
          %{
            "version" => "v0.9.1",
            "updateComponents" => %{
              "surfaceId" => "test",
              "components" => [
                %{"id" => "root", "component" => "ProgressBar", "value" => 42, "label" => "tests"}
              ]
            }
          }
        ],
        "\n",
        &JSON.encode!/1
      )

    rows = Blocks.rows("```a2ui\n" <> source <> "\n```", Theme.mono())
    assert Enum.any?(rows, &match?({:model_ui, _}, &1))
    assert text(RichText.lines(rows, 60, Theme.mono())) =~ "42"

    assert Enum.any?(
             Blocks.rows("```a2ui\n{}\n```", Theme.mono()),
             &match?({:model_drawing_error, _}, &1)
           )

    assert Enum.any?(
             Blocks.rows("```a2ui\n" <> source, Theme.mono()),
             &match?({:model_drawing_error, _}, &1)
           )
  end

  test "boot steps remain busy until their real completion and never show gallery telemetry" do
    state = TUI.new(theme: "mono")

    assert {:noreply, busy} =
             TUI.handle_info({:startup_step, :workspace, "Discover workspace", "busy"}, state)

    assert Enum.find(busy.terminal.boot.steps, &(&1.id == :workspace)).status == "busy"

    assert {:noreply, done} =
             TUI.handle_info({:startup_step, :workspace, "Discover workspace", "ok"}, busy)

    assert Enum.find(done.terminal.boot.steps, &(&1.id == :workspace)).status == "ok"
    text = Art.lines(done.terminal.boot.animation, "", 72, Theme.mono()) |> text()
    assert text =~ "Discover workspace"
    refute text =~ "kernel"

    refute text(
             TUI.Boot.render(done, %ExRatatui.Layout.Rect{width: 72, height: 20})
             |> Enum.flat_map(fn {widget, _} -> widget.text end)
           ) =~ "\n _"

    appended = TUI.Boot.observe(done, "extension:my_audit", "Initialize MyAudit", "busy")
    assert List.last(appended.terminal.boot.steps).status == "busy"
    completed = TUI.Boot.observe(appended, "extension:my_audit", "Initialize MyAudit", "ok")
    assert length(completed.terminal.boot.steps) == length(appended.terminal.boot.steps)
    assert List.last(completed.terminal.boot.steps).status == "ok"
    assert TUI.Boot.observe(done, make_ref(), "invalid id", "ok") == done
  end

  test "custom decoration opens in the first frame and disabling it keeps the boot log" do
    tasks = start_supervised!({Task.Supervisor, []})

    waiting = fn _app ->
      receive do
        :finish -> {:error, "fixture"}
      end
    end

    settings = %{"options" => %{"text" => "HELLO LMX"}, "duration_ms" => 220}

    assert {:ok, state} =
             TUI.mount(
               start_async: waiting,
               task_supervisor: tasks,
               startup_animation: settings,
               test_mode: {42, 17}
             )

    assert state.overlay.text == "HELLO LMX"
    assert state.overlay.frames == 2

    assert Enum.any?(TUI.render(state, %ExRatatui.Frame{width: 42, height: 17}), fn
             {%ExRatatui.Widgets.Paragraph{text: "HELLO LMX"}, _area} -> true
             _other -> false
           end)

    assert {:ok, disabled} =
             TUI.mount(
               start_async: waiting,
               task_supervisor: tasks,
               startup_animation: false,
               test_mode: {80, 24}
             )

    assert disabled.overlay == nil
    assert screen(disabled) =~ "Preparing session"

    for task <- [state.resume.initial_task, disabled.resume.initial_task],
        do: Task.shutdown(task, :brutal_kill)
  end

  test "a bounded appendable log keeps the pending handoff visible after many completed steps" do
    state =
      Enum.reduce(1..140, TUI.new(theme: "mono"), fn i, state ->
        TUI.Boot.observe(state, "step-#{i}", "Completed step #{i}", "ok")
      end)

    assert length(state.terminal.boot.steps) == 128
    [{widget, _}] = TUI.Boot.render(state, %ExRatatui.Layout.Rect{width: 72, height: 3})
    assert text(widget.text) =~ "Preparing session"
    refute text(widget.text) =~ "\n_"
    assert List.last(widget.text) |> then(&text([&1])) =~ "Preparing session"
  end

  test "data rows respect terminal cell widths and mono removes colours" do
    animation =
      Art.new("file-tree", %{
        paths: ["lib/測試.ex", "README.md"],
        walk: false,
        open: ["lib/"],
        rows: 8
      })

    for width <- [1, 12, 24, 40, 80] do
      lines = Art.lines(animation, "lib/測試.ex", width, Theme.mono())

      for line <- lines do
        assert Width.of(Enum.map_join(line.spans, & &1.content)) <= max(width, 2)
        assert Enum.all?(line.spans, &(is_nil(&1.style.fg) and is_nil(&1.style.bg)))
      end
    end
  end

  test "resume rebuilds the same visualization from the original assistant text" do
    source =
      Enum.map_join(
        [
          %{
            "version" => "v0.9.1",
            "createSurface" => %{
              "surfaceId" => "test",
              "catalogId" => AgentUI.catalog_id()
            }
          },
          %{
            "version" => "v0.9.1",
            "updateComponents" => %{
              "surfaceId" => "test",
              "components" => [
                %{
                  "id" => "root",
                  "component" => "Table",
                  "headers" => ["name", "count"],
                  "rows" => [["a", 3]]
                }
              ]
            }
          }
        ],
        "\n",
        &JSON.encode!/1
      )

    answer = "```a2ui\n" <> source <> "\n```"
    entry = %{type: :assistant, payload: %{"content" => [%{"type" => "text", "text" => answer}]}}
    restored = TUI.TranscriptPresentation.lines([entry], %{theme: Theme.mono(), renderers: %{}})

    assert text(RichText.lines(restored, 60, Theme.mono())) ==
             text(RichText.lines(Blocks.rows(answer, Theme.mono()), 60, Theme.mono()))

    assert Enum.any?(restored, &match?({:model_ui, _tree}, &1))
    assert entry.payload["content"] |> hd() |> Map.fetch!("text") == answer
  end

  defp text(lines),
    do: Enum.map_join(lines, "\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
end
