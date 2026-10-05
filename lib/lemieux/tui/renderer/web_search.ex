# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.WebSearch do
    @moduledoc """
    `web_search`: `Searched the web for “QUERY”`, then one exploration line
    per result — its title and the site it came from — in place of the raw
    output.

    The results are read from the payload's `"structured_content"`, which is
    the shape the search tool returns them in; a result without a title and
    a URL is skipped rather than drawn half-filled.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?) do
      query = arguments |> ToolText.argument("query") |> ToolText.one_line()

      [ToolText.heading(id, :search, "Searched the web for", "“#{query}”")]
    end

    @impl Lemieux.TUI.Renderer
    def result(%{id: id} = call, %{payload: payload}, _theme) do
      results = get_in(payload, ["structured_content", "results"]) || []

      rows =
        Enum.flat_map(results, fn
          %{"title" => title, "url" => url} when is_binary(title) and is_binary(url) ->
            [{:tool_detail, id, :explore, "#{ToolText.one_line(title)} — #{domain(url)}"}]

          _invalid ->
            []
        end)

      {:replace, call(call, false) ++ rows}
    end

    defp domain(url) do
      case URI.new(url) do
        {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
        _invalid -> "unknown source"
      end
    end
  end
end
