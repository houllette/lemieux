defmodule Lemieux.WebFetch.Markdown do
  @moduledoc """
  Preserves origin-served Markdown while discovering its heading and links.

  Negotiating Markdown saves downloading a site's HTML/hydration shell, but
  treating it as plain text used to lose the links needed by a following crawl.
  This bounded projection recognizes ordinary inline, reference and bare URL
  targets outside fenced code. It is not a full Markdown renderer.
  """
  alias Lemieux.WebFetch.HTML

  @links ~r/\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+"[^"]*")?\)|^\s*\[[^\]\n]+\]:\s*<?([^\s>]+)>?|https?:\/\/[^\s<>"\]]+/m

  @spec to_text(markdown :: String.t(), url :: String.t()) :: map()
  def to_text(markdown, url) do
    prose = without_code(markdown)
    links = @links |> Regex.scan(prose) |> Enum.map(&target/1) |> HTML.resolve_links(url)

    title =
      case Regex.run(~r/^#\s+(.+?)\s*#*\s*$/m, prose, capture: :all_but_first) do
        [title] -> String.slice(title, 0, 300)
        _ -> nil
      end

    %{text: String.trim(markdown), title: title, links: links, extraction: "markdown"}
  end

  defp target([whole | captures]),
    do: Enum.find(captures, fn value -> value != "" end) || String.trim_trailing(whole, ".")

  defp without_code(markdown) do
    {lines, _} =
      markdown
      |> String.split("\n")
      |> Enum.map_reduce(nil, fn line, fence ->
        marker = Regex.run(~r/^\s{0,3}(`{3,}|~{3,})/, line, capture: :all_but_first)

        cond do
          fence == nil and marker != nil -> {"", hd(marker)}
          fence != nil and marker != nil and String.starts_with?(hd(marker), fence) -> {"", nil}
          fence != nil -> {"", fence}
          true -> {line, nil}
        end
      end)

    Enum.join(lines, "\n")
  end
end
