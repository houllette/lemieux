# The matching is pure and unguarded, so its ranking is testable without the
# terminal dependency; the listing is a task the screen starts.
defmodule Lemieux.TUI.FileIndex do
  @moduledoc """
  Every file under the working directory, for the `@` picker's fuzzy search.

  The picker used to list one directory at a time and match names by prefix,
  which found `@lib/lemieux/tui/composer.ex` only for somebody who already
  knew it was there. With an index, `@compos` finds it: the letters of the
  query in order anywhere in the path, ranked the way a person means them.

  ## What is listed

  `Lemieux.Tools.Search.Files` — `rg --files`, else `git ls-files`, else a
  walk that reads `.gitignore` — so the picker offers what a developer's own
  search would, and nothing from `_build` or `node_modules`. It runs in a
  task through the session's environment, capped, and is listed again when
  it is more than a minute old; `render/2` only ever reads the list.

  ## How matches rank

  A path matches when every character of the query appears in it in order,
  ignoring case. Among matches:

    1. a match inside the file's own name beats one spread across its
       directories — `@turn` means `turn.ex`, not `test/unit/renderer.ex`;
    2. then more of the query matched in consecutive runs and at the start
       of a word (after `/`, `_`, `-`, `.`);
    3. then the shorter path.
  """

  alias Lemieux.Environment
  alias Lemieux.Tools.Search.Files

  @max_files 20_000
  @stale_ms 60_000
  @shown 50

  @doc """
  Starts listing `cwd` when there is no index or it is stale, and returns the
  references map to keep. The listing arrives as `{:file_index, cwd, files}`.
  """
  @spec ensure(references :: map(), now :: integer()) :: map()
  def ensure(%{cwd: nil} = references, _now), do: references
  def ensure(%{index: :loading} = references, _now), do: references

  def ensure(%{index: %{at: at}} = references, now) when now - at < @stale_ms, do: references

  def ensure(references, _now) do
    app = self()
    cwd = references.cwd
    environment = references.environment || Environment.local()

    Task.start(fn -> send(app, {:file_index, cwd, listed(environment, cwd)}) end)
    Map.put(references, :index, :loading)
  end

  # An index is a convenience: a listing that fails leaves the picker with
  # the directory it can already list, not a crashed screen.
  defp listed(environment, cwd) do
    {:ok, %{files: files}} = Files.list(environment, cwd, "", max_files: @max_files)

    files
  catch
    _kind, _reason -> []
  end

  @doc "Stores a finished listing if it is still for the working directory being shown."
  @spec loaded(references :: map(), cwd :: Path.t(), files :: [String.t()], now :: integer()) ::
          map()
  def loaded(%{cwd: cwd} = references, cwd, files, now),
    do: Map.put(references, :index, %{files: files, at: now})

  def loaded(references, _cwd, _files, _now), do: references

  @doc """
  The best `#{@shown}` paths in `files` for `query`, best first. See the
  moduledoc for the order.
  """
  @spec match(files :: [String.t()], query :: String.t(), limit :: pos_integer()) :: [String.t()]
  def match(files, query, limit \\ @shown) do
    needle = query |> String.downcase() |> String.graphemes()

    files
    |> Enum.flat_map(fn path ->
      case rank(path, needle) do
        nil -> []
        rank -> [{rank, path}]
      end
    end)
    |> Enum.sort()
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 1))
  end

  # A sort key, smaller first: file-name match, then score, then length.
  defp rank(path, needle) do
    lower = String.downcase(path)

    case score(String.graphemes(lower), needle) do
      nil ->
        nil

      score ->
        in_name? = score(lower |> Path.basename() |> String.graphemes(), needle) != nil
        {if(in_name?, do: 0, else: 1), -score, String.length(path)}
    end
  end

  # Greedy, leftmost: each query character takes the first place it fits.
  # Consecutive characters score more than scattered ones, and a character at
  # the start of a word more still.
  defp score(_path, []), do: 0

  defp score(path, needle), do: walk(path, needle, nil, nil, 0)

  defp walk(_path, [], _previous, _last, score), do: score
  defp walk([], _needle, _previous, _last, _score), do: nil

  defp walk([char | rest], [char | needle], previous, last, score) do
    bonus =
      cond do
        last == :matched -> 3
        previous in [nil, "/", "_", "-", ".", " "] -> 2
        true -> 1
      end

    walk(rest, needle, char, :matched, score + bonus)
  end

  defp walk([char | rest], needle, _previous, _last, score),
    do: walk(rest, needle, char, :skipped, score)
end
