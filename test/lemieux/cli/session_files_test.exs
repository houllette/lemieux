defmodule Lemieux.CLI.SessionFilesTest do
  # What a finished `lmx run` leaves in the sessions directory: its transcript,
  # owner-only, and no lock — every run used to leave `<id>.lock` behind.
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "a finished run leaves its transcript, private, and releases its lock", %{
    tmp_dir: tmp_dir
  } do
    sessions = Path.join(tmp_dir, "sessions")
    supervisor = :"lemieux_session_files_#{System.unique_integer([:positive])}"

    capture_io(:stderr, fn ->
      output =
        capture_io(fn ->
          assert CLI.run(["run", "hello"],
                   provider: Scripted.new([Scripted.complete("hi there")]),
                   store: JSONL.new(sessions),
                   supervisor: supervisor,
                   cwd: tmp_dir,
                   stdin_terminal?: true
                 ) == :ok
        end)

      assert output =~ "hi there"
    end)

    assert [transcript] = Path.wildcard(Path.join(sessions, "*.jsonl"))
    assert Path.wildcard(Path.join(sessions, "*.lock")) == []

    unless match?({:win32, _}, :os.type()) do
      assert (File.stat!(transcript).mode &&& 0o777) == 0o600
      assert (File.stat!(sessions).mode &&& 0o777) == 0o700
    end
  end
end
