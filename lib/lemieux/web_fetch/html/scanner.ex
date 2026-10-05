defmodule Lemieux.WebFetch.HTML.Scanner do
  @moduledoc false

  # A bounded projection, not a browser DOM implementation. A stack handles
  # nested/unterminated containers; raw-text elements are skipped before tags
  # are scanned, including script bundles cut by the HTTP body cap.
  @token ~r/\A<(?:[^"'<>]|"[^"]*"|'[^']*')*>/s
  @name ~r/\A<\s*(\/?)\s*([a-zA-Z][a-zA-Z0-9:-]*)/
  @attribute ~r/([^\s=\/<>'"]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/
  @raw ~w(script style noscript template svg iframe)
  @ends Map.new(@raw, &{&1, Regex.compile!("</#{&1}\\s*>", "i")})
  @void ~w(area base br col embed hr img input link meta param source track wbr)
  @head ~w(html head title base link meta)
  @blocks ~w(p div br hr li ul ol dl dt dd h1 h2 h3 h4 h5 h6 tr table section article header footer nav aside main blockquote pre figure figcaption form fieldset option details summary)
  @chrome ~r/(?:^|[\s_-])(sidebar|navigation|toc|cookie-banner|site-footer)(?:$|[\s_-])/i
  @root %{
    tag: "",
    drop: false,
    chrome: false,
    main: false,
    article: false,
    pre: false,
    title: false
  }

  @spec scan(html :: String.t()) :: map()
  def scan(html) do
    walk(html, %{
      stack: [@root],
      body: [],
      main: [],
      article: [],
      title: [],
      links: [],
      scripts: false,
      refresh: nil,
      head_open: true,
      truncated: false,
      tokens: 0
    })
  end

  defp walk("", state), do: state

  defp walk(_html, %{tokens: count} = state) when count >= 100_000,
    do: %{state | truncated: true}

  defp walk("<!--" <> rest, state), do: walk(after_marker(rest, "-->"), tick(state))

  defp walk("<" <> rest = html, state) do
    case Regex.run(@token, html) do
      [token] ->
        remaining = binary_part(html, byte_size(token), byte_size(html) - byte_size(token))
        {remaining, state} = tag(token, remaining, tick(state))
        walk(remaining, state)

      nil ->
        # An unfinished tag is not prose. A literal comparison such as < 3 is.
        if Regex.match?(~r/\A\/?[a-zA-Z!]/, rest),
          do: %{state | truncated: true},
          else: walk(rest, append(state, "<"))
    end
  end

  defp walk(html, state) do
    case :binary.match(html, "<") do
      {index, 1} ->
        <<text::binary-size(^index), rest::binary>> = html
        walk(rest, state |> tick() |> append(text))

      :nomatch ->
        append(state, html)
    end
  end

  defp tag(token, rest, state) do
    case Regex.run(@name, token, capture: :all_but_first) do
      ["/", name] -> {rest, close(state, String.downcase(name))}
      ["", name] -> open(state, String.downcase(name), token, rest)
      _ -> {rest, state}
    end
  end

  defp open(state, name, _token, rest) when name in @raw do
    state = %{state | scripts: state.scripts or name in ["script", "noscript"]}

    case Regex.run(Map.fetch!(@ends, name), rest, return: :index, capture: :first) do
      [{index, size}] -> {binary_part(rest, index + size, byte_size(rest) - index - size), state}
      nil -> {"", state}
    end
  end

  defp open(%{stack: stack} = state, _name, _token, _rest) when length(stack) >= 128,
    do: {"", %{state | truncated: true}}

  defp open(state, name, token, rest) do
    attrs = attributes(token)
    parent = hd(state.stack)

    state = %{
      state
      | stack: [frame(parent, name, attrs) | state.stack],
        head_open: state.head_open and name in @head
    }

    state = state |> separator(name) |> link(name, attrs) |> refresh(name, attrs)

    state =
      if name in @void or String.ends_with?(token, "/>"),
        do: %{state | stack: tl(state.stack)},
        else: state

    {rest, state}
  end

  defp frame(parent, name, attrs) do
    %{
      parent
      | tag: name,
        drop: parent.drop or name == "head" or hidden?(attrs),
        chrome: parent.chrome or chrome?(name, attrs, parent),
        main: parent.main or name == "main" or attrs["role"] == "main",
        article: parent.article or name == "article",
        pre: parent.pre or name == "pre",
        title: name == "title"
    }
  end

  defp close(state, name) do
    state = if name == "head", do: %{state | head_open: false}, else: state

    case Enum.split_while(state.stack, &(&1.tag != name)) do
      {_, []} ->
        state

      {_, [_matching | parents]} when parents != [] ->
        state = separator(state, name)
        %{state | stack: parents}

      _ ->
        state
    end
  end

  defp attributes(token) do
    [_name | attributes] =
      Regex.scan(@attribute, String.trim_leading(token, "<"), capture: :all_but_first)

    Map.new(attributes, fn [key | values] ->
      {String.downcase(key), Enum.find(values, "", &(&1 != ""))}
    end)
  end

  defp hidden?(attrs),
    do:
      Map.has_key?(attrs, "hidden") or attrs["aria-hidden"] == "true" or
        Regex.match?(~r/(?:display\s*:\s*none|visibility\s*:\s*hidden)/i, attrs["style"] || "")

  defp chrome?(name, attrs, parent),
    do:
      name in ~w(nav aside footer) or attrs["role"] in ~w(navigation banner contentinfo) or
        (name == "header" and not (parent.main or parent.article)) or
        Regex.match?(@chrome, (attrs["class"] || "") <> " " <> (attrs["id"] || ""))

  defp separator(state, "pre"), do: append(state, "\n```\n")
  defp separator(state, name) when name in @blocks, do: append(state, "\n")
  defp separator(state, name) when name in ~w(td th), do: append(state, " ")
  defp separator(state, _), do: state

  defp append(%{stack: [%{title: true} | _]} = state, text),
    do: %{state | title: [text | state.title]}

  defp append(%{stack: [%{drop: true} | _]} = state, _text), do: state
  defp append(%{stack: [%{chrome: true} | _]} = state, _text), do: state

  defp append(state, text) do
    frame = hd(state.stack)
    state = %{state | body: [text | state.body]}
    state = if frame.main, do: %{state | main: [text | state.main]}, else: state
    if frame.article, do: %{state | article: [text | state.article]}, else: state
  end

  defp link(%{stack: [%{drop: true} | _]} = state, _, _), do: state

  defp link(state, "a", %{"href" => href}) do
    frame = hd(state.stack)

    priority =
      cond do
        frame.chrome -> 3
        frame.article -> 0
        frame.main -> 1
        true -> 2
      end

    %{state | links: [{priority, href} | state.links]}
  end

  defp link(state, _, _), do: state

  defp refresh(%{refresh: nil} = state, "meta", %{"http-equiv" => equiv, "content" => content}) do
    # Static-site generators commonly omit the optional <head> tags. Accept
    # their leading metadata too, but never a refresh embedded in body prose.
    if String.downcase(equiv) == "refresh" and state.head_open do
      case Regex.run(~r/\A\s*0(?:\.0+)?\s*;\s*url\s*=\s*(.+?)\s*\z/i, content) do
        [_, target] -> %{state | refresh: String.trim(target, "\"'")}
        nil -> state
      end
    else
      state
    end
  end

  defp refresh(state, _, _), do: state

  defp after_marker(text, marker) do
    case :binary.match(text, marker) do
      {index, size} -> binary_part(text, index + size, byte_size(text) - index - size)
      :nomatch -> ""
    end
  end

  defp tick(state), do: %{state | tokens: state.tokens + 1}
end
