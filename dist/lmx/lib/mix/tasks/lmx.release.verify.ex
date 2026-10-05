defmodule Mix.Tasks.Lmx.Release.Verify do
  @shortdoc "Checks release assets against their .sig files"
  @moduledoc """
  Verifies each `FILE` against `FILE.sig` with the public key pinned in
  `release-signing.pub`, or with `--public-key BASE64`:

      mix lmx.release.verify SHA256SUMS update.json
      mix lmx.release.verify --public-key BASE64 SHA256SUMS

  Fails, listing every file that did not verify, when any signature is
  missing or wrong. It needs no private key, so anyone with a checkout can use
  it to check downloaded release assets.
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
    {opts, files, invalid} = OptionParser.parse(args, strict: [public_key: :string])

    unless files != [] and invalid == [],
      do: Mix.raise("usage: mix lmx.release.verify [--public-key BASE64] FILE...")

    with {:ok, key} <- key(opts[:public_key], root),
         :ok <- Signing.verify_files(files, key) do
      Enum.each(files, &Mix.shell().info("Verified #{&1}"))
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp key(nil, root) do
    case Signing.read_pinned(Path.join(root, "release-signing.pub")) do
      {:ok, {:ok, key}} ->
        {:ok, key}

      {:ok, :unset} ->
        {:error, "release-signing.pub is UNSET: no key is pinned yet; pass --public-key BASE64"}

      error ->
        error
    end
  end

  defp key(text, _root), do: Signing.parse_public_key(text)
end
