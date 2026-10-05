defmodule Lmx.Update.PayloadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Lmx.Update.Payload

  # What Python's tarfile "data" filter (install.py) leaves of a regular
  # file's mode. test/test_release_tools.py checks install.py's copy of this
  # rule against the filter itself and against :erl_tar.
  test "a file's mode is what the data filter would leave" do
    assert Payload.canonical_mode(0o100664) == 0o644
    assert Payload.canonical_mode(0o444) == 0o644
    assert Payload.canonical_mode(0o775) == 0o755
    assert Payload.canonical_mode(0o654) == 0o644
    assert Payload.canonical_mode(0o4755) == 0o755
    assert Payload.canonical_mode(0o600) == 0o600

    # The filter's output is its own fixed point, so a directory either
    # extractor made fingerprints the same as the other's.
    for mode <- 0..0o7777 do
      canonical = Payload.canonical_mode(mode)
      assert Payload.canonical_mode(canonical) == canonical
      assert (canonical &&& 0o022) == 0 and (canonical &&& 0o600) == 0o600
    end
  end

  # :erl_tar keeps an archive's 0664; install.py's filter leaves 0644. The
  # two directories hold the same release and must be recognised as such.
  @tag :tmp_dir
  @tag :unix
  test "directories two extractors made from one archive fingerprint the same", %{tmp_dir: tmp} do
    [kept, filtered] =
      for {name, grammar, launcher} <- [{"erl_tar", 0o664, 0o775}, {"data", 0o644, 0o755}] do
        root = Path.join(tmp, name)
        File.mkdir_p!(Path.join(root, "lib/jsv/priv"))
        File.mkdir_p!(Path.join(root, "bin"))
        File.write!(Path.join(root, "lib/jsv/priv/email.abnf"), "grammar")
        File.chmod!(Path.join(root, "lib/jsv/priv/email.abnf"), grammar)
        File.write!(Path.join(root, "bin/lmx"), "#!/bin/sh\n")
        File.chmod!(Path.join(root, "bin/lmx"), launcher)
        root
      end

    assert {:ok, fingerprint} = Payload.fingerprint(kept)
    assert {:ok, ^fingerprint} = Payload.fingerprint(filtered)

    # Execute permission is still part of what was verified.
    File.chmod!(Path.join(filtered, "lib/jsv/priv/email.abnf"), 0o755)
    refute Payload.fingerprint(filtered) == {:ok, fingerprint}
  end
end
