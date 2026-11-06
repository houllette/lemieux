defmodule Lemieux.CLI.Corpus do
  @moduledoc """
  Reviewed corpus growth from the command line.

      lmx corpus promote DRAFT_DIR MANIFEST --cluster ID [--tag T]... [--allow PATH]...
                         [--expect pass] [--allow-secret-files] [--reference DIR]
      lmx corpus review DRAFT_DIR --reference DIR --allow SOURCE_PATH...

  A draft is what `lmx feedback draft-case` froze. Promotion is the reviewed
  act of adding it to a manifest, and it proves the grader fails on the
  untouched fixture first; `--expect pass` is for read-only and refusal cases
  whose grader must pass untouched. A fixture holding a secret-shaped file
  (`Lemieux.Benchmark.SecretFiles`) is refused unless `--allow-secret-files`
  says the reviewer put it there on purpose. Nothing here runs a model.
  """

  alias Lemieux.Benchmark.Corpus.Promote

  @switches [
    cluster: :string,
    tag: [:string, :keep],
    allow: [:string, :keep],
    expect: :string,
    repos_dir: :string,
    allow_secret_files: :boolean,
    reference: :string,
    failure_exit_status: :integer
  ]

  @doc "Runs a corpus command without halting the VM."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(["review" | argv], _opts) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [draft_dir], []} ->
        draft_dir |> review(parsed) |> report_review()

      _invalid ->
        fail("usage: lmx corpus review DRAFT_DIR --reference DIR --allow SOURCE_PATH")
    end
  end

  def run(["promote" | argv], _opts) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [draft_dir, manifest], []} ->
        draft_dir |> Promote.promote(manifest, promote_options(parsed)) |> report(manifest)

      {_parsed, _rest, [{flag, _} | _]} ->
        fail("unrecognised corpus option #{flag}")

      _other ->
        fail(
          "usage: lmx corpus promote DRAFT_DIR MANIFEST --cluster ID [--tag T] [--allow PATH] [--expect pass] [--allow-secret-files] [--reference DIR]"
        )
    end
  end

  def run(_argv, _opts), do: fail("usage: lmx corpus promote DRAFT_DIR MANIFEST --cluster ID ...")

  defp review(draft_dir, parsed) do
    case Keyword.fetch(parsed, :reference) do
      {:ok, reference} -> Promote.review(draft_dir, reference, promote_options(parsed))
      :error -> {:error, :reference_required}
    end
  end

  defp report_review({:ok, review}) do
    IO.puts(JSON.encode!(review))
    if review["status"] == "passed", do: :ok, else: {:error, 1}
  end

  defp report_review({:error, reason}), do: fail("could not review: #{inspect(reason)}")

  defp promote_options(parsed) do
    [
      cluster_id: parsed[:cluster],
      tags: Keyword.get_values(parsed, :tag),
      allowed_changed_paths: Keyword.get_values(parsed, :allow),
      expect: if(parsed[:expect] == "pass", do: :pass, else: :fail),
      failure_exit_status: Keyword.get(parsed, :failure_exit_status, 1),
      allow_secret_files: Keyword.get(parsed, :allow_secret_files, false)
    ] ++
      if(parsed[:repos_dir], do: [repos_dir: parsed[:repos_dir]], else: []) ++
      if(parsed[:reference], do: [reference_dir: parsed[:reference]], else: [])
  end

  defp report({:ok, id}, manifest) do
    IO.puts("promoted case #{id} into #{manifest}")
    :ok
  end

  defp report({:error, :grader_passes_untouched_fixture}, _manifest) do
    fail(
      "the grader passes on the untouched fixture, so this case cannot discriminate; fix the verifier or pass --expect pass for a read-only case"
    )
  end

  defp report({:error, {:secret_files, paths}}, _manifest) do
    fail(
      "the fixture holds secret-shaped files (#{Enum.join(paths, ", ")}), and the corpus is meant to be committed; remove them, or pass --allow-secret-files if the case needs them and they hold nothing real"
    )
  end

  defp report({:error, {:verification_not_demonstrated, review}}, _manifest) do
    IO.puts(JSON.encode!(review))
    fail("matched public checks did not discriminate; the corpus was not changed")
  end

  defp report({:error, reason}, _manifest), do: fail("could not promote: #{inspect(reason)}")

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
