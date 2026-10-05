defmodule Lemieux.CLI.SourceUpdateRestartTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.SourceUpdate

  # `mix lmx` runs every lmx command from a source checkout; the restart
  # hint used to name `mix lmx.tui`, the older spelling of one of them.
  test "a source update says to restart mix lmx" do
    notice = SourceUpdate.restart_notice("0123456789abcdef0123")

    assert notice =~ "Source updated to 0123456789ab"
    assert notice =~ "run mix deps.get in your launch directory, then restart mix lmx to load it."
    refute notice =~ "mix lmx.tui"
  end
end
