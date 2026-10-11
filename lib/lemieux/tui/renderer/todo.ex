if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Todo do
    @moduledoc """
    A todo revision as a readable checklist. The persistent panel follows the
    newest plan; these receipts retain the revisions that led to it. Prefer
    structured plan data, with a text fallback for older saved transcripts.
    """
    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.Extensions.Planning
    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id}, _exploring?), do: [ToolText.heading(id, :todo, "Todo List:")]

    @impl Lemieux.TUI.Renderer
    def result(%{id: id}, %{payload: payload, output: output}, _theme) do
      case plan(payload, output) do
        {:ok, revision, tasks} ->
          done = Enum.count(tasks, &(&1["status"] == "completed"))

          heading =
            ToolText.heading(
              id,
              :todo,
              "Todo List:",
              "revision #{revision} · #{done}/#{length(tasks)} complete"
            )

          rows = Enum.map(tasks, &{:todo_item, id, &1["status"], ToolText.one_line(&1["title"])})
          rows = if rows == [], do: ToolText.detail(id, "No tasks"), else: rows
          {:replace, [heading | rows]}

        :unknown ->
          {:output, output}
      end
    end

    defp plan(
           %{
             "structured_content" => %{
               "revision" => revision,
               "plan" => %{"tasks" => tasks} = plan
             }
           },
           _output
         )
         when is_integer(revision) and is_list(tasks),
         do: {:ok, revision, Planning.tasks(plan)}

    defp plan(_payload, output) do
      case String.split(output, "\n") do
        ["Plan revision " <> revision | lines] ->
          with {revision, ""} <- Integer.parse(revision),
               tasks when is_list(tasks) <- legacy_tasks(lines) do
            {:ok, revision, tasks}
          else
            _invalid -> :unknown
          end

        _unknown ->
          :unknown
      end
    end

    defp legacy_tasks(lines) do
      Enum.reduce_while(lines, [], fn line, tasks ->
        case Regex.run(~r/^\S+ \[(pending|in_progress|completed|deleted)\] (.*)$/, line) do
          [_, "deleted", _title] -> {:cont, tasks}
          [_, status, title] -> {:cont, [%{"status" => status, "title" => title} | tasks]}
          _unknown -> {:halt, :unknown}
        end
      end)
      |> case do
        tasks when is_list(tasks) -> Enum.reverse(tasks)
        :unknown -> :unknown
      end
    end
  end
end
