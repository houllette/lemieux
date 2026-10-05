defmodule Mix.Tasks.Lmx.Release.Keygen do
  @shortdoc "Creates the offline release-signing key and pins its public key"
  @moduledoc """
  Creates the Ed25519 key that signs lmx releases. Run it once, from
  `dist/lmx`, on the machine that will keep the key:

      mix lmx.release.keygen --private-key /path/to/lmx-release.key

  The private key is written to that path with mode 0600. It is never printed,
  an existing file is never overwritten, and a path inside a Git checkout is
  refused. The public key is written to `release-signing.pub` and to the
  `RELEASE_PUBLIC_KEY` line of `scripts/install.py`; commit both, so every
  build and installer from then on pins it. Keep the private key offline (see
  RELEASING.md).

  A key that is already pinned is replaced only with `--rotate`: installed
  builds trust the key they were compiled with, so a new key has to reach them
  in a release signed with the old one.
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
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [private_key: :string, rotate: :boolean])

    unless rest == [] and invalid == [] and is_binary(opts[:private_key]),
      do: Mix.raise("usage: mix lmx.release.keygen --private-key PATH [--rotate]")

    path = Path.expand(opts[:private_key])
    public_key_file = Path.join(root, "release-signing.pub")
    installer = Path.expand("../../scripts/install.py", root)

    case Signing.keygen(path,
           public_key_file: public_key_file,
           installer: installer,
           rotate?: Keyword.get(opts, :rotate, false)
         ) do
      {:ok, public_key} ->
        exposed? = Signing.exposed?(path)

        Mix.shell().info("""
        Wrote the private key to #{path}#{if exposed?, do: "", else: " (mode 0600)"}. It was not printed; keep it in offline storage.
        Pinned public key #{public_key} in:
          #{public_key_file}
          #{installer}
        Commit both files. Builds and installers made from that commit verify releases with this key.
        """)

        # FAT and exFAT, common on the USB sticks keys are kept on, ignore
        # chmod: the file then stays readable by every local user.
        if exposed?,
          do:
            Mix.shell().error(
              "warning: #{path} is readable by other users: its filesystem ignores file " <>
                "modes. Move the key to storage only you can read."
            )

        :ok

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
