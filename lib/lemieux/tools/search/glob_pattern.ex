defmodule Lemieux.Tools.Search.GlobPattern do
  @moduledoc """
  Gitignore-style glob patterns, compiled once and matched against relative
  paths.

  `Lemieux.Tools.Glob`, the `glob` filter of `Lemieux.Tools.Grep` and the
  directory walk's `.gitignore` reader all need the same answer to "does this
  path match", whichever backend listed the files. `rg`, `git ls-files` and a
  plain walk each have their own idea of a glob; filtering every listing here
  as well is what keeps one pattern meaning one thing across all three.

  ## The dialect

  The one a model already writes for `rg --glob` and `.gitignore`:

    * a pattern with no `/` matches a file name at any depth, so `*.ex`
      finds `lib/a.ex` as well as `a.ex`;
    * a pattern with a `/` is anchored at the directory being searched, so
      `lib/*.ex` matches `lib/a.ex` and not `lib/sub/b.ex`; a leading `/` or
      `./` anchors explicitly and is dropped;
    * `**` as a whole segment crosses directories (`lib/**/*.ex`), `*` and
      `?` stay inside one, `[abc]`, `[!abc]` and `{ex,exs}` work as usual;
    * a trailing `/` names a directory and matches everything under it.

  The first rule is the one the obvious alternative (`Path.wildcard/1`
  semantics, where `*.ex` means the top level only) gets wrong for a model:
  it asks for `*.ex`, gets the three files at the root, and concludes the
  project has three Elixir files.

  Matching is case-sensitive and dotfiles are ordinary names, as they are
  for `rg` and `.gitignore`.
  """

  @enforce_keys [:source, :regex]
  defstruct [:source, :regex]

  @typedoc "A compiled pattern."
  @type t :: %__MODULE__{source: String.t(), regex: Regex.t()}

  @doc """
  Compiles `pattern`, anchoring it as described in the module documentation.
  """
  @spec compile(pattern :: String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(pattern) when is_binary(pattern) do
    case normalize(pattern) do
      "" ->
        {:error, "the glob pattern is empty"}

      normalized ->
        case Regex.compile("\\A" <> translate(normalized) <> "\\z", "u") do
          {:ok, regex} -> {:ok, %__MODULE__{source: pattern, regex: regex}}
          {:error, {reason, _at}} -> {:error, "invalid glob #{inspect(pattern)}: #{reason}"}
        end
    end
  end

  def compile(_pattern), do: {:error, "the glob pattern must be a string"}

  @doc "Whether the relative `path` (separated by `/`) matches."
  @spec match?(pattern :: t(), path :: String.t()) :: boolean()
  def match?(%__MODULE__{regex: regex}, path) when is_binary(path),
    do: Regex.match?(regex, path)

  @doc """
  Translates a gitignore-style pattern into a regular-expression body,
  without anchors.

  Exposed for `Lemieux.Tools.Search.Ignore`, which anchors a pattern at the
  directory holding the `.gitignore` that declared it rather than at the
  search root.
  """
  @spec translate(pattern :: String.t()) :: String.t()
  def translate(pattern) when is_binary(pattern) do
    pattern
    |> String.graphemes()
    |> body([])
  end

  # Anchoring is decided here, before translation, because it is a property of
  # the whole pattern: whether a `/` appears anywhere but the end.
  defp normalize(pattern) do
    {pattern, directory?} = pattern |> String.trim() |> directory()
    {pattern, anchored?} = anchor(pattern)
    place(pattern, directory?, anchored?)
  end

  defp directory("/"), do: {"/", false}

  defp directory(pattern) do
    if String.ends_with?(pattern, "/"),
      do: {String.trim_trailing(pattern, "/"), true},
      else: {pattern, false}
  end

  defp anchor("./" <> pattern), do: {pattern, true}
  defp anchor("/" <> pattern), do: {pattern, true}
  defp anchor(pattern), do: {pattern, String.contains?(pattern, "/")}

  defp place("", _directory?, _anchored?), do: ""
  defp place(pattern, true, true), do: pattern <> "/**"
  defp place(pattern, true, false), do: "**/" <> pattern <> "/**"
  defp place(pattern, false, true), do: pattern
  defp place("**" <> _rest = pattern, false, false), do: pattern
  defp place(pattern, false, false), do: "**/" <> pattern

  # `**` is only special as a whole segment. Elsewhere it is two `*`s, which is
  # what both git and rg do with `a**b`.
  @any_directories "(?:[^/]*/)*"

  defp body(["*", "*", "/" | rest], acc) when acc == [] or hd(acc) in ["/", @any_directories],
    do: body(rest, [@any_directories | acc])

  defp body(["*", "*"], acc) when acc == [] or hd(acc) in ["/", @any_directories],
    do: body([], [".*" | acc])

  defp body(["*" | rest], acc), do: body(rest, ["[^/]*" | acc])
  defp body(["?" | rest], acc), do: body(rest, ["[^/]" | acc])
  defp body(["\\", char | rest], acc), do: body(rest, [Regex.escape(char) | acc])

  defp body(["[" | rest] = chars, acc) do
    case class(rest, []) do
      {:ok, class, rest} -> body(rest, [class | acc])
      :error -> body(tl(chars), ["\\[" | acc])
    end
  end

  defp body(["{" | rest] = chars, acc) do
    case alternatives(rest, 0, [], []) do
      {:ok, choices, rest} ->
        group = "(?:" <> Enum.map_join(choices, "|", &translate/1) <> ")"
        body(rest, [group | acc])

      :error ->
        body(tl(chars), ["\\{" | acc])
    end
  end

  defp body(["/" | rest], acc), do: body(rest, ["/" | acc])
  defp body([char | rest], acc), do: body(rest, [Regex.escape(char) | acc])
  defp body([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A bracket expression never matches `/`, as in git. An unterminated `[` is
  # a literal bracket rather than an error: `[` in a file name is legal and a
  # model searching for `a[1].txt` should find it.
  defp class(["!" | rest], []), do: negated_class(rest)
  defp class(["^" | rest], []), do: negated_class(rest)
  defp class(chars, []), do: class_body(chars, [], false)

  defp negated_class(chars), do: class_body(chars, [], true)

  defp class_body(["]" | rest], acc, negated?) when acc != [] do
    members = acc |> Enum.reverse() |> IO.iodata_to_binary()
    prefix = if negated?, do: "[^/", else: "(?!/)["
    {:ok, prefix <> members <> "]", rest}
  end

  defp class_body(["\\", char | rest], acc, negated?),
    do: class_body(rest, [class_escape(char) | acc], negated?)

  defp class_body([char | rest], acc, negated?),
    do: class_body(rest, [class_escape(char) | acc], negated?)

  defp class_body([], _acc, _negated?), do: :error

  defp class_escape("-"), do: "-"
  defp class_escape(char) when char in ["\\", "]", "[", "^"], do: "\\" <> char
  defp class_escape(char), do: char

  # Splits `a,b{c,d},e}` into top-level alternatives; nested braces are left
  # for the recursive `translate/1` of each alternative.
  defp alternatives(["}" | rest], 0, current, done),
    do: {:ok, Enum.reverse([join(current) | done]), rest}

  defp alternatives(["," | rest], 0, current, done),
    do: alternatives(rest, 0, [], [join(current) | done])

  defp alternatives(["\\", char | rest], depth, current, done),
    do: alternatives(rest, depth, [char, "\\" | current], done)

  defp alternatives(["{" | rest], depth, current, done),
    do: alternatives(rest, depth + 1, ["{" | current], done)

  defp alternatives(["}" | rest], depth, current, done),
    do: alternatives(rest, depth - 1, ["}" | current], done)

  defp alternatives([char | rest], depth, current, done),
    do: alternatives(rest, depth, [char | current], done)

  defp alternatives([], _depth, _current, _done), do: :error

  defp join(chars), do: chars |> Enum.reverse() |> Enum.join()
end
