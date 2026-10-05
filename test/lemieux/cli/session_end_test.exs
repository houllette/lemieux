defmodule Lemieux.CLI.SessionEndTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # The failure these guard against: a `sessionEnd` hook that never ran. The
  # standalone binary ends in `System.halt/1`, which runs nobody's
  # `terminate/2`, so a session the host merely walked away from never
  # reported its end. Each host must stop its session itself, synchronously,
  # before it returns — which is why the reason asserted here is `:normal`
  # (a deliberate `GenServer.stop/3`) and not the `:shutdown` a supervisor
  # teardown would deliver, asynchronously, if the VM lived long enough.

  setup %{tmp_dir: tmp_dir} do
    %{
      store: JSONL.new(tmp_dir),
      supervisor: :"lemieux_session_end_test_#{System.unique_integer([:positive])}"
    }
  end

  defp hooks(parent) do
    [session_end: fn reason, context -> send(parent, {:ended, reason, context.session_id}) end]
  end

  test "lmx run stops its session before returning, so session_end hooks see the run end",
       context do
    opts = [
      provider: Scripted.new([Scripted.complete("hello")]),
      store: context.store,
      supervisor: context.supervisor,
      hooks: hooks(self())
    ]

    capture_io(fn ->
      capture_io(:stderr, fn -> assert :ok = CLI.run(["run", "say hi"], opts) end)
    end)

    assert_received {:ended, :normal, session_id}
    assert {:ok, [_ | _]} = Lemieux.Store.read(context.store, session_id)
    assert Lemieux.sessions(context.supervisor) == []
  end
end
