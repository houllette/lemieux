defmodule Lemieux.Scripts.CheckLinks do
  @moduledoc """
  Checks tracked Markdown links as GitHub renders them, without network access.

  Synthetic repositories under eval/corpus and test/fixtures are inputs, not
  documentation. Dependencies linked by generated usage rules exist only after
  deps.get. Other relative paths must be tracked, Markdown fragments must name
  a heading, and URLs into the owner's other repositories are refused. A ref
  other than main warns because rewriting history can orphan that link.
  """

  @excluded ["eval/corpus/", "test/fixtures/"]
  @fence ~r/^\s{0,3}(`{3,}|~{3,})(.*)$/
  @inline ~r/!?\[(?:[^\[\]\n]|\n(?!\s*\n)|\[(?:[^\[\]\n]|\n(?!\s*\n))*\])*\]\(\s*(<[^>\n]*>|(?:[^()\s]|\((?:[^()\s])*\))*)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/
  @reference ~r/^\s{0,3}\[(?!\^)[^\]\n]+\]:\s*(<[^>\n]+>|\S+)/m
  @autolink ~r/<(https?:\/\/[^>\s]+)>/
  @html_link ~r/<(?:a|img|source)\s[^>]*?(?:href|src)\s*=\s*["']([^"']+)["']/i
  @bare ~r/https?:\/\/[^\s<>"'`|\\]+/
  @explicit ~r/<[a-z][a-z0-9]*\s[^>]*?\b(?:name|id)\s*=\s*["']([^"']+)["']/i
  @owner ~r/(?:https?:\/\/(?:www\.)?github\.com\/|https?:\/\/raw\.githubusercontent\.com\/|git@github\.com:)houllette\/([A-Za-z0-9._-]+)/i
  # The HTML5 character-reference table is data, not another runtime or a
  # dependency. Keeping the complete table preserves headings such as &eacute;
  # instead of silently supporting only XML's five named entities.
  @entities __DIR__ |> Path.join("html_entities.json") |> File.read!() |> JSON.decode!()

  @spec main(argv :: [String.t()]) :: 0 | 1 | 2
  def main(argv) do
    case OptionParser.parse(argv, strict: [root: :string]) do
      {opts, files, []} ->
        root = Keyword.get(opts, :root, Path.expand("../..", __DIR__))

        case run(root, files) do
          {:ok, result} ->
            report(result)

          {:error, message} ->
            IO.puts(:stderr, "check_links: " <> message)
            2
        end

      _invalid ->
        IO.puts(:stderr, "usage: elixir scripts/check_links.exs [--root ROOT] [FILE.md ...]")
        2
    end
  end

  @spec run(root :: Path.t(), only :: [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def run(root, only \\ []) do
    with {:ok, repo} <- repository(Path.expand(root)),
         {:ok, sources} <- sources(repo, only) do
      result =
        Enum.reduce(
          sources,
          %{errors: %{}, warnings: %{}, files: length(sources), links: 0},
          fn source, acc ->
            if String.ends_with?(source, ".md"), do: check_markdown(repo, source, acc), else: acc
          end
        )

      scope =
        if only == [], do: repo.files |> Enum.reject(&excluded?/1) |> Enum.sort(), else: sources

      {:ok, Enum.reduce(scope, result, &private_links(repo, &1, &2))}
    end
  end

  @spec extract_links(text :: String.t()) :: [{pos_integer(), String.t()}]
  def extract_links(text) do
    masked = mask_code(text)
    links = Enum.flat_map([@inline, @reference, @autolink, @html_link], &link_matches(&1, masked))
    seen = MapSet.new(links)

    bare =
      for [{offset, size}] <- Regex.scan(@bare, masked, return: :index),
          do: {line_of(masked, offset), trim_url(binary_part(masked, offset, size))}

    (links ++ Enum.reject(Enum.uniq(bare), &MapSet.member?(seen, &1)))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp link_matches(regex, text) do
    for [{offset, _size}, {start, size}] <- Regex.scan(regex, text, return: :index) do
      destination =
        text
        |> binary_part(start, size)
        |> String.trim()
        |> String.trim_leading("<")
        |> String.trim_trailing(">")

      {line_of(text, offset),
       if(regex == @html_link, do: unescape(destination), else: destination)}
    end
  end

  @spec anchors(text :: String.t()) :: MapSet.t(String.t())
  def anchors(text) do
    {found, _counts} =
      Enum.reduce(headings(text), {MapSet.new(), %{}}, fn title, {found, counts} ->
        base =
          title
          |> heading_text()
          |> String.downcase()
          |> String.replace(~r/[^ \p{L}\p{M}\p{N}\p{Pc}-]/u, "")
          |> String.replace(" ", "-")

        repeat = Map.get(counts, base, 0)
        anchor = if repeat == 0, do: base, else: "#{base}-#{repeat}"
        {MapSet.put(found, anchor), Map.put(counts, base, repeat + 1)}
      end)

    Enum.reduce(Regex.scan(@explicit, text, capture: :all_but_first), found, fn [name], acc ->
      MapSet.put(acc, String.downcase(name))
    end)
  end

  defp fenced_lines(text) do
    {lines, _fence} =
      Enum.map_reduce(String.split(text, "\n"), nil, fn line, fence ->
        fenced_line(line, fence, Regex.run(@fence, line))
      end)

    lines
  end

  defp fenced_line(line, nil, nil), do: {{line, false}, nil}

  defp fenced_line(line, nil, [_full, marks, _tail]),
    do: {{line, true}, {String.first(marks), String.length(marks)}}

  defp fenced_line(line, {char, size} = fence, [_full, marks, tail]) do
    next =
      if String.first(marks) == char and String.length(marks) >= size and String.trim(tail) == "",
        do: nil,
        else: fence

    {{line, true}, next}
  end

  defp fenced_line(line, fence, _match), do: {{line, true}, fence}

  defp mask_code(text) do
    masked =
      text
      |> fenced_lines()
      |> Enum.map_join("\n", fn {line, hidden?} -> if hidden?, do: blank(line), else: line end)

    masked = Regex.replace(~r/<!--.*?-->/s, masked, &blank/1)

    Regex.replace(~r/(?<!`)(`+)(?!`)((?:(?!\n\s*\n).)+?)(?<!`)\1(?!`)/s, masked, fn full,
                                                                                    _ticks,
                                                                                    _code ->
      blank(full)
    end)
  end

  defp blank(text), do: String.replace(text, ~r/[^\n]/u, " ")

  defp line_of(text, offset),
    do: text |> binary_part(0, offset) |> :binary.matches("\n") |> length() |> Kernel.+(1)

  defp trim_url(url) do
    url = String.trim_trailing(url, ".") |> String.replace(~r/[.,;:!?*_~]+$/, "")

    if String.ends_with?(url, ")") and
         length(:binary.matches(url, ")")) > length(:binary.matches(url, "(")),
       do: url |> binary_part(0, byte_size(url) - 1) |> trim_url(),
       else: url
  end

  defp headings(text) do
    {titles, _previous} = Enum.reduce(fenced_lines(text), {[], nil}, &heading/2)
    Enum.reverse(titles)
  end

  defp heading({_line, true}, {titles, _previous}), do: {titles, nil}

  defp heading({line, false}, {titles, previous}) do
    atx = Regex.run(~r/^\s{0,3}(\x23{1,6})(?:[ \t]+(.*?))?[ \t]*$/, line)
    setext? = Regex.match?(~r/^\s{0,3}(?:=+|-+)\s*$/, line)
    heading_line(atx, setext?, line, titles, previous)
  end

  defp heading_line([_full, _marks | rest], _setext?, _line, titles, _previous) do
    title = rest |> List.first("") |> String.trim() |> String.replace(~r/[ \t]+\x23+$/, "")
    title = if String.trim(title, "#") == "", do: "", else: title
    {[title | titles], nil}
  end

  defp heading_line(nil, true, _line, titles, previous) when is_binary(previous),
    do: {[String.trim(previous) | titles], nil}

  defp heading_line(nil, _setext?, line, titles, _previous) do
    stripped = String.trim(line)
    paragraph? = stripped != "" and not Regex.match?(~r/^(?:[-*+]\s|\d+[.)]\s|\||>|<)/, stripped)
    {titles, if(paragraph?, do: line)}
  end

  defp heading_text(raw) do
    spans = Regex.scan(~r/(`+)(.+?)\1/, raw)

    stashed =
      Enum.with_index(spans)
      |> Enum.reduce(raw, fn {[full, _ticks, _body], index}, text ->
        String.replace(text, full, <<0>> <> to_string(index) <> <<0>>, global: false)
      end)

    text =
      stashed
      |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
      |> String.replace(~r/\[([^\]]*)\]\[[^\]]*\]/, "\\1")
      |> String.replace(~r/<[^>]+>/, "")
      |> String.replace(~r/(\*\*|__)(.+?)\1/, "\\2")
      |> String.replace(~r/(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)/, "\\1")
      |> String.replace(~r/(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)/, "\\1")
      |> String.replace(~r/~~(.+?)~~/, "\\1")
      |> String.replace(~r/\\(.)/, "\\1")

    Enum.with_index(spans)
    |> Enum.reduce(text, fn {[_full, _ticks, body], index}, text ->
      String.replace(text, <<0>> <> to_string(index) <> <<0>>, body)
    end)
    |> unescape()
  end

  defp unescape(text),
    do:
      Regex.replace(~r/&(#(?:[xX][0-9a-fA-F]+|[0-9]+);?|[A-Za-z][A-Za-z0-9]*;?)/u, text, fn _full,
                                                                                            entity ->
        entity(entity)
      end)

  defp entity("#" <> value) do
    {value, base} =
      case String.trim_trailing(value, ";") do
        <<char, rest::binary>> when char in ~c"xX" -> {rest, 16}
        number -> {number, 10}
      end

    codepoint = String.to_integer(value, base)

    cond do
      Map.has_key?(@entities["replacements"], to_string(codepoint)) ->
        @entities["replacements"][to_string(codepoint)]

      codepoint in 0xD800..0xDFFF or codepoint > 0x10FFFF ->
        "�"

      codepoint in @entities["invalid"] ->
        ""

      true ->
        <<codepoint::utf8>>
    end
  end

  defp entity(name), do: named_entity(name, name)
  defp named_entity("", original), do: "&" <> original

  defp named_entity(prefix, original) do
    case Map.fetch(@entities["names"], prefix) do
      {:ok, decoded} -> decoded <> String.replace_prefix(original, prefix, "")
      :error -> named_entity(String.slice(prefix, 0, String.length(prefix) - 1), original)
    end
  end

  defp repository(root) do
    case System.cmd("git", ["-C", root, "ls-files", "-z"], stderr_to_stdout: true) do
      {listing, 0} ->
        files = listing |> String.split(<<0>>, trim: true) |> MapSet.new()
        directories = files |> Enum.flat_map(&parents(Path.dirname(&1))) |> MapSet.new()
        texts = Map.new(Enum.reject(files, &excluded?/1), &{&1, read_text(root, &1)})

        anchors =
          for {name, text} <- texts,
              is_binary(text),
              String.ends_with?(name, ".md"),
              into: %{},
              do: {name, anchors(text)}

        {:ok,
         %{root: root, files: files, directories: directories, texts: texts, anchors: anchors}}

      _failed ->
        {:error, "#{root} is not a Git checkout"}
    end
  end

  defp parents("."), do: []
  defp parents(path), do: [path | parents(Path.dirname(path))]
  defp excluded?(path), do: String.starts_with?(path, @excluded)

  defp read_text(root, name) do
    case File.read(Path.join(root, name)) do
      {:ok, bytes} -> if String.valid?(bytes), do: bytes
      _unreadable -> nil
    end
  end

  defp sources(repo, []),
    do:
      {:ok,
       repo.files
       |> Enum.filter(&(String.ends_with?(&1, ".md") and not excluded?(&1)))
       |> Enum.sort()}

  defp sources(repo, only) do
    Enum.reduce_while(only, {:ok, []}, fn name, {:ok, paths} ->
      path = name |> Path.expand() |> Path.relative_to(repo.root)

      if outside?(path),
        do: {:halt, {:error, "#{name} is outside #{repo.root}"}},
        else: {:cont, {:ok, paths ++ [path]}}
    end)
  end

  defp outside?(path),
    do: Path.type(path) == :absolute or path == ".." or String.starts_with?(path, "../")

  defp text(repo, name), do: Map.get_lazy(repo.texts, name, fn -> read_text(repo.root, name) end)

  defp target_problem(repo, name) do
    cond do
      MapSet.member?(repo.files, name) ->
        if not File.exists?(Path.join(repo.root, name)),
          do: "is tracked but deleted in this working tree"

      MapSet.member?(repo.directories, String.trim_trailing(name, "/")) ->
        nil

      File.exists?(Path.join(repo.root, name)) ->
        "exists here but is not tracked (git add it)"

      true ->
        "does not exist"
    end
  end

  defp fragment_problem(repo, target, fragment) do
    fragment = URI.decode(fragment)
    anchors = Map.get_lazy(repo.anchors, target, fn -> anchors(text(repo, target) || "") end)

    unless fragment == "" or Regex.match?(~r/^L\d+(?:C\d+)?(?:-L\d+(?:C\d+)?)?$/, fragment) or
             MapSet.member?(anchors, String.downcase(fragment)),
           do: "no heading in #{target} has the anchor ##{fragment}"
  end

  defp check_markdown(repo, source, result) do
    case text(repo, source) do
      nil ->
        finding(result, :errors, source, 0, "is not readable UTF-8 text")

      bytes ->
        links = extract_links(bytes)

        Enum.reduce(links, %{result | links: result.links + length(links)}, fn {line, destination},
                                                                               acc ->
          {error, warning} = check_destination(repo, source, destination)

          acc
          |> finding(:errors, source, line, error)
          |> finding(:warnings, source, line, warning)
        end)
    end
  end

  defp check_destination(_repo, _source, ""), do: {"a link has an empty destination", nil}

  defp check_destination(repo, source, destination) do
    uri = URI.parse(destination)

    cond do
      uri.scheme in ~w(http https) ->
        {error, warning} = self_url(repo, uri)
        {prefix(destination, error), prefix(destination, warning)}

      uri.scheme != nil or String.starts_with?(destination, "//") ->
        {nil, nil}

      true ->
        {prefix(destination, relative_problem(repo, source, uri)), nil}
    end
  end

  defp relative_problem(repo, source, uri) do
    path = URI.decode(uri.path || "")

    target =
      cond do
        path == "" ->
          source

        String.starts_with?(path, "/") ->
          path
          |> String.trim_leading("/")
          |> Path.expand(repo.root)
          |> Path.relative_to(repo.root)

        true ->
          path
          |> Path.expand(Path.join(repo.root, Path.dirname(source)))
          |> Path.relative_to(repo.root)
      end

    cond do
      target == "." or outside?(target) -> "points outside the repository"
      String.starts_with?(target, "deps/") -> nil
      true -> target_and_fragment(repo, target, uri.fragment)
    end
  end

  defp target_and_fragment(repo, target, fragment) do
    case target_problem(repo, target) do
      nil ->
        if fragment && String.ends_with?(target, ".md"),
          do: fragment_problem(repo, target, fragment)

      problem ->
        target <> " " <> problem
    end
  end

  defp self_url(repo, uri) do
    parts = String.split(uri.path || "", "/", trim: true)

    if String.downcase(uri.host || "") in ~w(github.com www.github.com),
      do: self_path(repo, uri, parts),
      else: {nil, nil}
  end

  defp self_path(repo, uri, [owner, name, kind, ref | path]) when kind in ~w(blob tree raw) do
    cond do
      String.downcase(owner) != "houllette" or String.downcase(name) != "lemieux" ->
        {nil, nil}

      ref != "main" ->
        {nil, "names the ref #{ref} rather than main; a history rewrite can orphan it"}

      path == [] ->
        {nil, nil}

      true ->
        {target_and_fragment(repo, path |> Enum.join("/") |> URI.decode(), uri.fragment), nil}
    end
  end

  defp self_path(_repo, _uri, _parts), do: {nil, nil}
  defp prefix(_destination, nil), do: nil
  defp prefix(destination, message), do: destination <> ": " <> message

  defp private_links(repo, source, result) do
    bytes = text(repo, source) || ""

    Enum.reduce(Regex.scan(@owner, bytes, return: :index), result, fn [
                                                                        {offset, size},
                                                                        {start, length}
                                                                      ],
                                                                      acc ->
      name =
        bytes
        |> binary_part(start, length)
        |> String.replace_suffix(".git", "")
        |> String.downcase()

      if name == "lemieux",
        do: acc,
        else:
          finding(
            acc,
            :errors,
            source,
            line_of(bytes, offset),
            binary_part(bytes, offset, size) <>
              ": a private repository; the link is dead for everyone else"
          )
    end)
  end

  defp finding(result, _kind, _source, _line, nil), do: result

  defp finding(result, kind, source, line, message),
    do:
      Map.update!(
        result,
        kind,
        &Map.update(&1, source, [{line, message}], fn found -> [{line, message} | found] end)
      )

  defp report(result) do
    for {kind, label} <- [warnings: "warning", errors: "error"],
        {name, entries} <- Enum.sort(result[kind]),
        {line, message} <- entries |> Enum.uniq() |> Enum.sort() do
      IO.puts("#{name}:#{line}: #{label}: #{message}")
    end

    errors = Enum.sum(Enum.map(result.errors, fn {_name, entries} -> length(entries) end))
    warnings = Enum.sum(Enum.map(result.warnings, fn {_name, entries} -> length(entries) end))

    IO.puts(
      "check_links: #{result.files} Markdown files, #{result.links} links: #{errors} broken, #{warnings} warnings"
    )

    if errors == 0, do: 0, else: 1
  end
end
