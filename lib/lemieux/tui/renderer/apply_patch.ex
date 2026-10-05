# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.ApplyPatch do
    @moduledoc """
    `apply_patch`: `Patching` and the files a patch names while it runs,
    then each file's change as a diff.

    The patch is read with the tool's own parser
    (`Lemieux.Tools.ApplyPatch.Parser`), so the rows show what was applied
    rather than a guess at the format. A patch's hunks carry context lines
    but no line numbers — the format finds its place by the context — so an
    update is drawn unnumbered, with each hunk's `@@` heading above it.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.Tools.ApplyPatch.Parser
    alias Lemieux.TUI.Diff
    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?) do
      subject =
        case Parser.parse(patch(arguments)) do
          {:ok, operations} -> operations |> Parser.paths() |> Enum.join(", ")
          {:error, _reason} -> ""
        end

      [ToolText.heading(id, :edit, "Patching", subject)]
    end

    @impl Lemieux.TUI.Renderer
    def result(%{id: id, arguments: arguments}, %{output: output}, theme) do
      case Parser.parse(patch(arguments)) do
        {:ok, operations} -> {:replace, Enum.flat_map(operations, &rows(id, &1, theme))}
        {:error, _reason} -> {:output, output}
      end
    end

    defp rows(id, %{type: :add, path: path, lines: lines}, theme) do
      [ToolText.heading(id, :write, "Added", "#{path} (+#{length(lines)})")] ++
        ToolText.diff_rows(id, Diff.unified([], lines), language(path), theme)
    end

    defp rows(id, %{type: :delete, path: path}, _theme),
      do: [ToolText.heading(id, :edit, "Deleted", path)]

    defp rows(id, %{type: :update, path: path, move_to: move_to, chunks: chunks}, theme) do
      diffs =
        Enum.map(
          chunks,
          &Diff.unified(&1.old, &1.new, old_start: nil, new_start: nil, context: 2)
        )

      {added, removed} = diffs |> Enum.concat() |> Diff.counts()
      moved = if move_to, do: " → #{move_to}", else: ""

      [ToolText.heading(id, :edit, "Updated", "#{path}#{moved} (+#{added} -#{removed})")] ++
        Enum.flat_map(Enum.zip(chunks, diffs), fn {chunk, lines} ->
          context(id, chunk) ++ ToolText.diff_rows(id, lines, language(path), theme)
        end)
    end

    defp context(_id, %{contexts: []}), do: []

    defp context(id, %{contexts: contexts}),
      do: ToolText.detail(id, "@@ " <> Enum.join(contexts, " › "))

    defp patch(arguments), do: arguments["input"] || arguments["patch"] || ""

    defp language(path), do: ToolText.language_of(path)
  end
end
