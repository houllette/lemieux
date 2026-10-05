defmodule Mix.Tasks.Lmx.Release.Sign do
  @shortdoc "Signs release assets with the offline release key"
  @moduledoc """
  Writes `FILE.sig` next to each file: the base64 Ed25519 signature over the
  file's exact bytes, which installed lmx builds and `scripts/install.py`
  verify.

      mix lmx.release.sign --private-key /path/to/lmx-release.key SHA256SUMS update.json

  The key must belong to the public key pinned in `release-signing.pub`, since
  builds reject signatures by any other key. `--public-key BASE64` names a
  different expected public key instead: the previous key during a key
  rotation, or a throwaway key for test fixtures. A key file inside a Git
  checkout is refused.
  `mix lmx.release.sign_draft` signs a draft GitHub release in one step.
  """
  use Mix.Task

  alias Lmx.Update.Signing

  @requirements ["compile"]

  @impl Mix.Task
  def run(args), do: run(args, Path.dirname(Mix.Project.project_file()))

  @doc false
  # `root` is the dist/lmx directory; tests pass a copy of the layout.
  @spec run(args :: [String.t()], root :: Path.t()) :: :ok
  def run(args, root) do
    {opts, files, invalid} =
      OptionParser.parse(args, strict: [private_key: :string, public_key: :string])

    unless files != [] and invalid == [] and is_binary(opts[:private_key]),
      do:
        Mix.raise("usage: mix lmx.release.sign --private-key PATH [--public-key BASE64] FILE...")

    path = Path.expand(opts[:private_key])

    if Signing.exposed?(path),
      do:
        Mix.shell().error(
          "warning: #{path} is readable by other users; chmod 600 it or keep it offline"
        )

    with {:ok, private_key} <- Signing.read_private_key(path),
         {:ok, pinned} <- expected(opts[:public_key], root),
         {:ok, written} <- Signing.sign_files(files, private_key, pinned) do
      Enum.each(written, &Mix.shell().info("Signed #{Path.rootname(&1, ".sig")} -> #{&1}"))
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp expected(nil, root), do: Signing.read_pinned(Path.join(root, "release-signing.pub"))

  defp expected(text, _root) do
    with {:ok, key} <- Signing.parse_public_key(text), do: {:ok, {:ok, key}}
  end
end
