defmodule Mix.Tasks.Lmx.Upgrade.Unpack do
  @shortdoc "Verifies and unpacks a prior release archive"
  @moduledoc """
      mix lmx.upgrade.unpack --archive lmx_macos_silicon.tar.gz \\
        --checksums SHA256SUMS --output /tmp/previous

  The output must be fresh. Rejects invalid checksums and unsafe tar entries.
  """
  use Mix.Task
  @requirements ["compile"]
  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [archive: :string, checksums: :string, output: :string])

    if rest != [] or invalid != [] or !opts[:archive] or !opts[:checksums] or !opts[:output],
      do: Mix.raise("provide --archive FILE --checksums FILE --output DIRECTORY")

    Lmx.UpgradePlan.unpack!(opts[:archive], opts[:checksums], opts[:output])
  end
end
