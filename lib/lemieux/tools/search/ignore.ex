defmodule Lemieux.Tools.Search.Ignore do
  @moduledoc """
  `.gitignore` rules for the directory walk the search tools fall back to.

  `rg` and `git ls-files` already honour ignore files, and one of them answers
  nearly every search. The walk exists for a directory with neither — an
  unpacked archive, a scratch folder — and without these rules it would
  search `node_modules` and a build directory before the code anybody asked
  about, then run out of budget.

  The subset is the one that decides what gets skipped in practice: blank
  lines and `#` comments, `!` negation, a trailing `/` for directories only,
  anchoring by a `/` anywhere but the end, and the glob syntax of
  `Lemieux.Tools.Search.GlobPattern`. Rules from a nested `.gitignore` apply
  below its directory, and the last matching rule wins, as in git. A path
  under an ignored directory is never visited, so a negation cannot bring it
  back — which is git's rule too.

  `default/0` adds the directories no search wants even when nothing ignores
  them: version-control metadata, dependency and build trees.
  """

  alias Lemieux.Tools.Search.GlobPattern

  @enforce_keys [:regex, :negate?, :directory_only?]
  defstruct [:regex, :negate?, :directory_only?]

  @typedoc "One compiled ignore rule."
  @type rule :: %__MODULE__{regex: Regex.t(), negate?: boolean(), directory_only?: boolean()}

  @default_directories ~w(
    .git .hg .svn _build deps node_modules target .elixir_ls __pycache__
    .venv venv .tox .mypy_cache .pytest_cache .next .nuxt .gradle .terraform
  )

  @doc """
  Rules for directories nobody means to search, whatever the ignore files say.
  """
  @spec default() :: [rule()]
  def default do
    Enum.flat_map(@default_directories, &parse_line(&1 <> "/", ""))
  end

  @doc """
  Parses the contents of a `.gitignore` that lives in `base`, a directory
  relative to the search root (`""` for the root itself).
  """
  @spec parse(contents :: String.t(), base :: String.t()) :: [rule()]
  def parse(contents, base) when is_binary(contents) and is_binary(base) do
    contents
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(&parse_line(&1, base))
  end

  @doc """
  Whether `path`, relative to the search root, is ignored by `rules`.

  `directory?` says whether the path names a directory, which rules ending in
  `/` require.
  """
  @spec ignored?(rules :: [rule()], path :: String.t(), directory? :: boolean()) :: boolean()
  def ignored?(rules, path, directory?) when is_list(rules) and is_binary(path) do
    Enum.reduce(rules, false, fn rule, ignored? ->
      cond do
        rule.directory_only? and not directory? -> ignored?
        Regex.match?(rule.regex, path) -> not rule.negate?
        true -> ignored?
      end
    end)
  end

  defp parse_line(line, base) do
    line = trim_unescaped_trailing_spaces(line)

    cond do
      line == "" -> []
      String.starts_with?(line, "#") -> []
      true -> rule(line, base)
    end
  end

  defp rule(line, base) do
    {line, negate?} =
      case line do
        "!" <> rest -> {rest, true}
        "\\!" <> rest -> {"!" <> rest, false}
        "\\#" <> rest -> {"#" <> rest, false}
        other -> {other, false}
      end

    {line, directory_only?} =
      if String.ends_with?(line, "/"),
        do: {String.trim_trailing(line, "/"), true},
        else: {line, false}

    anchored? = String.contains?(line, "/")
    compile(String.trim_leading(line, "/"), base, anchored?, negate?, directory_only?)
  end

  defp compile("", _base, _anchored?, _negate?, _directory_only?), do: []

  # A rule that does not compile is skipped rather than failing the search: an
  # ignore file is somebody else's text, and one odd line in it should not make
  # every search in the directory an error.
  defp compile(pattern, base, anchored?, negate?, directory_only?) do
    prefix = if base == "", do: "", else: Regex.escape(base) <> "/"
    depth = if anchored?, do: "", else: "(?:[^/]*/)*"
    source = "\\A" <> prefix <> depth <> GlobPattern.translate(pattern) <> "\\z"

    case Regex.compile(source, "u") do
      {:ok, regex} ->
        [%__MODULE__{regex: regex, negate?: negate?, directory_only?: directory_only?}]

      {:error, _reason} ->
        []
    end
  end

  # Trailing spaces are insignificant unless escaped with a backslash, as in git.
  defp trim_unescaped_trailing_spaces(line) do
    trimmed = String.trim_trailing(line, " ")

    if String.ends_with?(trimmed, "\\") and trimmed != line,
      do: trimmed <> " ",
      else: String.trim_trailing(trimmed, "\r")
  end
end
