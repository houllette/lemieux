defmodule Lemieux.WebFetch.HTML do
  @moduledoc """
  A bounded readable projection of HTML with no parser dependency.

  The scanner tracks nested containers and quoted attributes, drops hidden
  and raw script/style content (including unfinished hydration scripts), and
  prefers article/main text over navigation. This is deliberately smaller than
  a browser's HTML parser: it does not implement CSS layout or HTML5 error
  recovery. Token/depth limits are surfaced rather than silently hiding a cut.

  Links in content precede ordinary body links and navigation. Fragment-only,
  same-page and credential-bearing targets are excluded; duplicate fragments
  share one target. A sparse scripted page is labelled for an optional host
  renderer, never itself permission to bypass the public HTTP address checks.
  """

  alias Lemieux.WebFetch.HTML.Scanner

  @max_links 20
  @max_title_chars 300

  @typedoc "The readable projection of one HTML document."
  @type t :: %{
          title: String.t() | nil,
          text: String.t(),
          links: [String.t()],
          extraction: String.t(),
          needs_render: boolean(),
          parser_truncated: boolean(),
          redirect: String.t() | nil
        }

  @entity ~r/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z][a-zA-Z0-9]{1,9});/
  @named %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "laquo" => "«",
    "raquo" => "»",
    "middot" => "·",
    "bull" => "•",
    "times" => "×",
    "euro" => "€",
    "pound" => "£",
    "yen" => "¥",
    "deg" => "°",
    "eacute" => "é",
    "egrave" => "è",
    "agrave" => "à",
    "ccedil" => "ç",
    "ntilde" => "ñ",
    "auml" => "ä",
    "ouml" => "ö",
    "uuml" => "ü",
    "szlig" => "ß"
  }

  @doc """
  Converts `html` to text. `:base` is the page's own URL, used to make
  relative link targets absolute; without it only absolute links are kept.
  """
  @spec to_text(html :: String.t(), opts :: [base: String.t()]) :: t()
  def to_text(html, opts \\ []) when is_binary(html) and is_list(opts) do
    scanned = Scanner.scan(html)
    candidates = for key <- [:article, :main, :body], do: {key, readable(scanned[key])}
    {region, text} = Enum.find(candidates, {:body, ""}, fn {_, text} -> text != "" end)
    title = scanned.title |> readable() |> collapse_spaces() |> String.slice(0, @max_title_chars)

    %{
      title: if(title == "", do: nil, else: title),
      text: text,
      links: links(scanned.links, Keyword.get(opts, :base)),
      extraction: Atom.to_string(region),
      needs_render:
        scanned.scripts and String.length(text) < 200 and
          (text == "" or
             Regex.match?(
               ~r/\A(?:loading\b|please wait\b|(?:please )?enable javascript|this (?:page|app) requires? javascript)/i,
               text
             )),
      parser_truncated: scanned.truncated,
      redirect: if(scanned.refresh && not scanned.truncated, do: decode_entities(scanned.refresh))
    }
  end

  @doc "Decodes the numeric and common named character references in `text`."
  @spec decode_entities(text :: String.t()) :: String.t()
  def decode_entities(text) when is_binary(text) do
    Regex.replace(@entity, text, fn whole, reference -> entity(whole, reference) end)
  end

  defp readable(parts),
    do: parts |> Enum.reverse() |> IO.iodata_to_binary() |> decode_entities() |> collapse()

  defp links(candidates, base) do
    candidates
    |> Enum.reverse()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> resolve_links(base)
  end

  @doc "Resolves ordered link candidates, drops unsafe/self targets and deduplicates fragments."
  @spec resolve_links(candidates :: [String.t()], base :: String.t() | nil) :: [String.t()]
  def resolve_links(candidates, base) do
    candidates
    |> Enum.map(&(decode_entities(&1) |> String.trim()))
    |> Enum.flat_map(&absolute(&1, base))
    |> Enum.reject(&(without_fragment(&1) == without_fragment(base)))
    |> Enum.uniq_by(&without_fragment/1)
    |> Enum.take(@max_links)
  end

  defp without_fragment(nil), do: nil
  defp without_fragment(url), do: url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()

  defp absolute("", _base), do: []
  defp absolute("#" <> _fragment, _base), do: []

  defp absolute(href, base) do
    merged = if base, do: base |> URI.merge(href) |> URI.to_string(), else: href

    case URI.new(merged) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) ->
        [merged]

      _other ->
        []
    end
  rescue
    ArgumentError -> []
  end

  defp entity(whole, "#x" <> hex), do: codepoint(whole, Integer.parse(hex, 16))
  defp entity(whole, "#" <> decimal), do: codepoint(whole, Integer.parse(decimal, 10))
  defp entity(whole, name), do: Map.get(@named, name, whole)

  defp codepoint(_whole, {code, ""})
       when code in 0x20..0xD7FF or code in 0xE000..0x10FFFF or code in [0x09, 0x0A, 0x0D],
       do: <<code::utf8>>

  defp codepoint(whole, _invalid), do: whole

  defp collapse(text) do
    {lines, _} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, code? ->
        cond do
          String.trim(line) == "```" -> {"```", not code?}
          code? -> {line, code?}
          true -> {collapse_spaces(line), code?}
        end
      end)

    lines |> Enum.join("\n") |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim()
  end

  defp collapse_spaces(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
