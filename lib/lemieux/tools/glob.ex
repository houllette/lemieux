defmodule Lemieux.Tools.Glob do
  @moduledoc """
  Lists the files under a directory whose paths match a glob, read-only and
  confined to the working directory.

  The companion to `Lemieux.Tools.Grep`, for the question that comes before
  "where is this called": "where are the tests", "which files are
  migrations". `read` on a directory answers one level at a time, and `find`
  in `bash` descends into `node_modules` and `_build` unless the model
  remembers to prune them; this honours `.gitignore` and caps its answer.

  The pattern dialect is `Lemieux.Tools.Search.GlobPattern`'s, the same one
  `grep`'s `glob` filter uses: without a `/` a pattern matches file names at
  any depth, with one it is anchored at `path`. Paths come back relative to
  the working directory, sorted, one per line, so they can be passed to
  `read` unchanged.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Search.Files
  alias Lemieux.Tools.Search.GlobPattern
  alias Lemieux.Tools.Search.Scope

  @default_results 200
  @max_results 2_000

  @impl Lemieux.Tool
  def name, do: "glob"

  @impl Lemieux.Tool
  def description do
    """
    Find files by path pattern. Respects .gitignore. Returns matching paths
    relative to the working directory, sorted, one per line.

    A pattern without / matches file names at any depth: "*.ex",
    "*_test.exs", "*.{ts,tsx}". A pattern with / is anchored at path:
    "lib/**/*.ex", "test/*_test.exs". ** crosses directories; * and ? do not.
    Results are capped, and the output says when there are more.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob to match, for example \"**/*.ex\" or \"test/**/*_test.exs\"."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory to search, relative to the working directory. " <>
              "Defaults to the working directory."
        },
        "max_results" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_results,
          "description" => "Most paths to return. Defaults to #{@default_results}."
        }
      },
      "required" => ["pattern"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool
  def parallel_safe?, do: true

  @impl Lemieux.Tool
  def read_only?, do: true

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{
        class: "read",
        resource_types: ["directory"],
        idempotent: true,
        retryable: true
      },
      policy: %{approval: "never"},
      runtime: %{concurrency: %{class: "parallel"}, max_output_bytes: 60_000, timeout_ms: 60_000}
    }
  end

  @impl Lemieux.Tool
  def run(%{"pattern" => pattern} = args, context) when is_binary(pattern) and pattern != "" do
    environment = Environment.from_context(context)
    limit = args |> limit() |> min(@max_results) |> max(1)

    with {:ok, glob} <- GlobPattern.compile(pattern),
         {:ok, scope} <- Scope.resolve(environment, context.cwd, Map.get(args, "path")),
         :ok <- directory(scope, Map.get(args, "path")),
         {:ok, listing} <- Files.list(environment, context.cwd, scope.relative) do
      matches = Enum.filter(listing.files, &GlobPattern.match?(glob, &1))
      {:ok, render(matches, limit, listing, scope, pattern)}
    end
  end

  def run(%{"pattern" => _pattern}, _context), do: {:error, "glob needs a non-empty pattern"}
  def run(_args, _context), do: {:error, "glob needs a pattern"}

  defp limit(%{"max_results" => value}) when is_integer(value), do: value
  defp limit(_args), do: @default_results

  defp directory(%{kind: :directory}, _path), do: :ok

  defp directory(%{kind: :file}, path),
    do: {:error, "#{path}: is a file; glob searches a directory. Use read to open it."}

  defp render(matches, limit, listing, scope, pattern) do
    shown = Enum.take(matches, limit)
    more? = length(matches) > limit
    lines = Enum.map(shown, &Scope.display(scope, &1))

    summary =
      cond do
        shown == [] ->
          "No files match #{inspect(pattern)} in #{Scope.describe(scope)}."

        more? ->
          "[showing #{length(shown)} of #{length(matches)} files; narrow the pattern or " <>
            "path, or raise max_results]"

        true ->
          "[#{length(shown)} #{if length(shown) == 1, do: "file", else: "files"}]"
      end

    summary =
      if listing.complete?,
        do: summary,
        else: summary <> "\n[the file listing was cut short, so some files may be missing]"

    text = if lines == [], do: summary, else: Enum.join(lines, "\n") <> "\n\n" <> summary

    Result.new(text,
      metadata: %{
        "backend" => Atom.to_string(listing.backend),
        "files" => length(shown),
        "truncated" => more? or not listing.complete?
      }
    )
  end
end
