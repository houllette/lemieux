defmodule Lemieux.CLI.JevCompactionTest do
  # The library's own suite has no Jev extension loaded, which is the case a
  # source checkout of the library meets. The bundled case is covered by the
  # release host's suite (dist/lmx/test/lmx/jev_compaction_test.exs).
  use ExUnit.Case, async: true

  alias Lemieux.CLI.{Config, JevCompaction}

  test "without the extension, an unconfigured or switched-off host adds nothing" do
    assert JevCompaction.spec(%Config{}, nil) == {:ok, nil}
    assert JevCompaction.spec(nil, nil) == {:ok, nil}

    off = %Config{settings: %{"jev_compaction" => %{"mode" => "off", "api_key" => "unused"}}}
    assert JevCompaction.spec(off, nil) == {:ok, nil}
  end

  test "asking for Jev without the extension names where the bundled one lives" do
    config = %Config{settings: %{"jev_compaction" => %{"mode" => "apply"}}}

    assert {:error, message} = JevCompaction.spec(config, nil)
    assert message =~ "the installed lmx bundles"
    assert message =~ "dist/lmx/extensions/jev_compaction"
    refute message =~ "examples/"
  end
end
