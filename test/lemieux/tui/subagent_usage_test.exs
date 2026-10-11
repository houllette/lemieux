defmodule Lemieux.TUI.SubagentUsageTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Selection
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.Transcript
  alias Lemieux.TUI.TranscriptPresentation

  test "each player's parenthesis accumulates only that child's reported tokens" do
    state =
      tui()
      |> queued("child-a")
      |> queued("child-b")
      |> usage("child-a", %{"input_tokens" => 1_000, "output_tokens" => 100})
      |> usage("child-b", %{
        "input_tokens" => 400,
        "cache_read_tokens" => 50,
        "output_tokens" => 50
      })
      |> usage("child-a", %{
        "input_tokens" => 500,
        "cache_read_tokens" => 200,
        "cache_write_tokens" => 50,
        "output_tokens" => 100,
        "input_includes_cached" => true
      })

    assert child(state, "child-a").tokens == 1_700
    assert child(state, "child-b").tokens == 500
    assert screen(state) =~ "#{Shorthand.of("child-a")} (1.7k tokens)"
    assert screen(state) =~ "#{Shorthand.of("child-b")} (500 tokens)"
    assert Enum.count(state.lines, &match?({:subagent_child, _}, &1)) == 2
  end

  test "the durable result replaces the live total, including assessment overhead, once" do
    result =
      Entry.new(:subagent_result, %{
        "child_id" => "child",
        "status" => "ok",
        "usage" => %{
          "input_tokens" => 1_200,
          "cache_read_tokens" => 300,
          "cache_write_tokens" => 100,
          "output_tokens" => 100
        }
      })

    state =
      tui()
      |> queued("child")
      |> usage("child", %{"input_tokens" => 1_000, "output_tokens" => 100})
      |> info({:entry, result})
      |> info({:entry, result})
      |> info(
        {:subagent, ["root"], {:child_finished, %{"child_id" => "child", "status" => "ok"}}}
      )

    assert child(state, "child").tokens == 1_700
    assert screen(state) =~ "#{Shorthand.of("child")} (1.7k tokens) · ok"
    assert usage(state, "child", %{"input_tokens" => 1_000}).lines == state.lines
  end

  test "replay uses the per-child result and never adds the group aggregate again" do
    spawned =
      Entry.new(:subagent_spawn, %{
        "child_id" => "child",
        "task" => %{"objective" => "Inspect runtime"}
      })

    result =
      Entry.new(:subagent_result, %{
        "child_id" => "child",
        "status" => "ok",
        "usage" => %{
          "input_tokens" => 1_000,
          "cache_read_tokens" => 200,
          "output_tokens" => 100,
          "input_includes_cached" => true
        }
      })

    group =
      Entry.new(:subagent_group_result, %{
        "status" => "ok",
        "results" => [result.payload],
        "usage" => result.payload["usage"]
      })

    rows =
      TranscriptPresentation.lines([spawned, result, group], %{
        theme: Theme.dark(),
        renderers: Renderer.builtin(),
        width: 80
      })

    assert [{:subagent_child, %{tokens: 1_100}}] =
             Enum.filter(rows, &match?({:subagent_child, _}, &1))

    text =
      rows
      |> RichText.lines(80)
      |> Enum.map_join("\n", &Enum.map_join(&1.spans, fn span -> span.content end))

    assert text =~ "#{Shorthand.of("child")} (1.1k tokens) · ok · Inspect runtime"
  end

  test "missing usage stays pending or unavailable while a measured zero remains zero" do
    pending = queued(tui(), "child")
    assert screen(pending) =~ "#{Shorthand.of("child")} (tokens pending)"
    assert child(pending, "child").tokens == nil
    assert usage(pending, "child", %{}).lines == pending.lines
    measured = usage(pending, "child", %{"input_tokens" => 0, "output_tokens" => 0})
    assert screen(measured) =~ "#{Shorthand.of("child")} (0 tokens)"
    result = Entry.new(:subagent_result, %{"child_id" => "child", "status" => "failed"})

    assert screen(info(pending, {:entry, result})) =~
             "#{Shorthand.of("child")} (tokens unavailable) · failed"
  end

  test "token growth that wraps a headline keeps older scroll and selection anchored" do
    row =
      {:subagent_child,
       %{
         id: "child",
         name: "someplayer",
         status: "running",
         tokens: 9,
         kind: nil,
         goal: nil,
         activity: nil,
         count: 1,
         text: nil
       }}

    state =
      tui(
        lines: Enum.map(1..30, &{:lmx, "older line #{&1}"}) ++ [row],
        scroll: 10,
        selection: %Selection{anchor: {20, 0}, cursor: {20, 4}}
      )

    state = put_in(state.terminal.width, 37)
    before = Transcript.rows(state, row)
    updated = usage(state, "child", %{"input_tokens" => 10_000})
    delta = Transcript.rows(updated, {:subagent_child, child(updated, "child")}) - before
    assert delta == 1
    assert updated.scroll == state.scroll + delta
    assert updated.selection.anchor == {21, 0}
    assert updated.selection.cursor == {21, 4}
  end

  defp queued(state, id),
    do: info(state, {:subagent, ["root"], {:child_queued, %{"child_id" => id}}})

  defp usage(state, id, usage), do: info(state, {:subagent, ["root", id], {:usage, usage}})

  defp child(state, id),
    do:
      Enum.find_value(state.lines, fn
        {:subagent_child, %{id: ^id} = child} -> child
        _row -> nil
      end)
end
