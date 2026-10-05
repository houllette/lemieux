defmodule Mix.Tasks.Lmx.Release.SignDraft do
  @shortdoc "Signs a draft GitHub release's SHA256SUMS and update.json"
  @moduledoc """
  Signs the draft release that release CI built for a tag, without publishing
  it:

      mix lmx.release.sign_draft --tag v1.2.3 --private-key /path/to/lmx-release.key

  Uses the GitHub CLI (`gh`, authenticated for the repository) to download the
  draft's `SHA256SUMS`, `update.json` and `install.py`, checks that they
  describe that version and pin the same key as `release-signing.pub`, signs
  `SHA256SUMS` and `update.json`, uploads `SHA256SUMS.sig` and
  `update.json.sig` to the draft, and downloads and verifies them again.
  It never publishes: review the draft and publish it yourself.
  `--repo OWNER/NAME` signs a fork's draft instead. A key file inside a Git
  checkout is refused.

  Before signing, it also checks that `update.json` and `SHA256SUMS` name the
  same archives with the same digests. It cannot tell whether the draft's
  assets are what the tagged workflow run built: first compare the draft's
  `SHA256SUMS` with the one in that run's uploaded candidate artifact
  (`complete-release-candidate` in release.yml; see RELEASING.md).
  """
  use Mix.Task

  alias Lmx.Update.Signing

  @requirements ["compile"]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  # Tests pass `root:` (a copy of the dist/lmx layout) and `runner:` (a stub `gh`).
  @spec run(args :: [String.t()], overrides :: keyword()) :: :ok
  def run(args, overrides) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [tag: :string, private_key: :string, repo: :string])

    unless rest == [] and invalid == [] and is_binary(opts[:tag]) and
             is_binary(opts[:private_key]),
           do:
             Mix.raise(
               "usage: mix lmx.release.sign_draft --tag vX.Y.Z --private-key PATH [--repo OWNER/NAME]"
             )

    root = Keyword.get_lazy(overrides, :root, fn -> Path.dirname(Mix.Project.project_file()) end)
    path = Path.expand(opts[:private_key])

    if Signing.exposed?(path),
      do:
        Mix.shell().error(
          "warning: #{path} is readable by other users; chmod 600 it or keep it offline"
        )

    with {:ok, private_key} <- Signing.read_private_key(path),
         {:ok, pinned} <- Signing.read_pinned(Path.join(root, "release-signing.pub")),
         {:ok, lines} <-
           Signing.sign_draft(
             opts[:tag],
             private_key,
             [pinned: pinned, repo: Keyword.get(opts, :repo, "houllette/lemieux")] ++
               Keyword.take(overrides, [:runner])
           ) do
      Enum.each(lines, fn line -> Mix.shell().info(line) end)
    else
      {:error, message} -> Mix.raise(message)
    end
  end
end
