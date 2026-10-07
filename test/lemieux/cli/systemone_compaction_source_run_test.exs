defmodule Lemieux.CLI.SystemOneCompactionSourceRunTest do
  # The release host in dist/lmx has a deps directory of its own, which a fresh
  # clone has not fetched, so the hint has to fetch it before running: it used
  # to say only `cd dist/lmx && mix lmx.tui`, which stopped on the missing
  # dependencies. Like `Lemieux.CLI.SystemOneCompactionTest`, this runs where the
  # extension is not loaded, which is the case the hint is for.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.{Config, SystemOneCompaction}

  test "asking for the step from a source checkout names a sequence that works in a fresh clone" do
    config = %Config{settings: %{"systemone_compaction" => %{"mode" => "apply"}}}

    assert {:error, message} = SystemOneCompaction.spec(config, nil)

    assert message =~
             "`cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`"

    refute message =~ "mix lmx.tui"
  end
end
