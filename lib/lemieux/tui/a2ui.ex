if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.A2UI do
    @moduledoc """
    Projects validated, closed A2UI fences into transcript rows once.

    Read-only means no component owns input or invokes a tool, opens a URL,
    reads a file, or evaluates code. Source remains in the event-sourced
    transcript; this projection is rebuilt on resume and on theme changes.
    Unsupported documents return a diagnostic; source stays on the record.
    """
    alias Lemieux.Extensions.A2UI.Rendering
    alias Lemieux.TUI.A2UI.Layout
    alias Lemieux.TUI.Art
    alias Lemieux.TUI.Diagrams
    alias Lemieux.TUI.Width

    @doc "Turns a self-contained message stream into display rows."
    @spec rows(source :: String.t()) ::
            {:ok, [Lemieux.TUI.Blocks.row()]} | {:error, String.t()} | :error
    def rows(source) do
      with {:ok, trees} <- Rendering.prepare(source) do
        {:ok, Enum.map(trees, &{:model_ui, present(&1)})}
      end
    end

    defp present(%{"component" => type, "children" => children} = node)
         when type in ["Column", "Row"] do
      node |> Map.put("children", Enum.map(children, &present/1)) |> Layout.measure()
    end

    defp present(%{diagram: prepared} = node) do
      node
      |> Map.delete(:diagram)
      |> Map.put(:rows, [{:model_diagram, Diagrams.project(prepared)}])
      |> Layout.measure()
    end

    defp present(node), do: node |> Map.put(:rows, row(node)) |> Layout.measure()

    defp row(%{"component" => "Text", "text" => text}),
      do: Enum.map(String.split(text, "\n"), &{:model, &1})

    defp row(%{"component" => "ProgressBar", "value" => value, "label" => label}),
      do: [Art.progress(value, label)]

    defp row(%{"component" => "Sparkline"} = node) do
      animation =
        Art.new("sparkline", %{
          series: [
            %{
              label: node["label"],
              values: node["values"],
              unit: Map.get(node, "unit", ""),
              digits: 2
            }
          ],
          rate: node["sampleRate"],
          range: false,
          rows: 3,
          # Short measured series need less of the gallery's empty history
          # window. Explicit layout width or stretch can still enlarge it.
          cols: min(72, max(40, length(node["values"]) + 24))
        })

      [
        {:model_art, animation,
         "#{node["label"]}: #{Enum.join(node["values"], ", ")} #{Map.get(node, "unit", "")}"}
      ]
    end

    defp row(%{"component" => "BarChart"} = node) do
      animation =
        Art.new("bar-chart", %{
          title: node["title"],
          labels: node["labels"],
          datasets: [%{name: node["title"], values: node["values"]}]
        })

      description =
        Enum.zip(node["labels"], node["values"])
        |> Enum.map_join(", ", fn {label, value} -> "#{label} #{value}" end)

      [{:model_art, animation, node["title"] <> ": " <> description}]
    end

    defp row(%{"component" => "Table", "headers" => headers, "rows" => rows}),
      do: [
        {:model_table,
         %{
           header: headers,
           aligns: List.duplicate(:left, length(headers)),
           rows: Enum.map(rows, fn row -> Enum.map(row, &to_string/1) end)
         }}
      ]

    defp row(%{"component" => "FileTree"} = node) do
      paths = node["paths"]

      animation =
        Art.new("file-tree", %{
          paths: paths,
          walk: false,
          open: folders(paths),
          root: Map.get(node, "root", "."),
          rows: min(length(paths) + length(folders(paths)) + 3, 100),
          cols: min(max(Enum.max(Enum.map(paths, &Width.of/1)) + 8, 12), 200)
        })

      [{:model_art, animation, "#{Map.get(node, "root", ".")}:\n" <> Enum.join(paths, "\n")}]
    end

    @doc false
    @spec folders(paths :: [String.t()]) :: [String.t()]
    def folders(paths),
      do:
        paths
        |> Enum.flat_map(fn path ->
          parts = String.split(path, "/") |> Enum.drop(-1)

          parts
          |> Enum.scan(fn part, prefix -> prefix <> "/" <> part end)
          |> Enum.map(&(&1 <> "/"))
        end)
        |> Enum.uniq()
  end
end
