defmodule Lemieux.CLI.JevCompactionSourceRunTest do
  # The release host in dist/lmx has a deps directory of its own, which a fresh
  # clone has not fetched, so the hint has to fetch it before running: it used
  # to say only `cd dist/lmx && mix lmx.tui`, which stopped on the missing
  # dependencies. Like `Lemieux.CLI.JevCompactionTest`, this runs where the
  # extension is not loaded, which is the case the hint is for.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.{Config, JevCompaction}

  test "asking for Jev from a source checkout names a sequence that works in a fresh clone" do
    config = %Config{settings: %{"jev_compaction" => %{"mode" => "apply"}}}

    assert {:error, message} = JevCompaction.spec(config, nil)

    assert message =~
             "`cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`"

    refute message =~ "mix lmx.tui"
  end
end
