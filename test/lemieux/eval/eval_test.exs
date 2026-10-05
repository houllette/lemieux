defmodule Lemieux.EvalTest do
  @moduledoc """
  The host-facing end of the evaluation node, reached with nothing but a
  session pid.

  Attaching to somebody else's application needs distribution and lives in
  `Lemieux.Eval.AttachTest`. What is proven here is the part that does not:
  that a front end holding a session can ask where it evaluates and send it
  home without the session knowing an evaluation node exists.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Eval
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_eval_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(tmp_dir),
        model: "test:model",
        tools: [Tools.Eval],
        cwd: tmp_dir
      )

    %{runtime: runtime, session: session, tmp_dir: tmp_dir}
  end

  defp sandboxes(runtime, session),
    do: Registry.lookup(Sup.registry(runtime), {:elixir_sandbox, Session.id(session)})

  test "a session that has never evaluated is on no node but its own, and has started none",
       %{runtime: runtime, session: session} do
    assert Eval.attached(session) == nil
    assert sandboxes(runtime, session) == []
  end

  test "detaching a session that never attached is a success on its own node",
       %{runtime: runtime, session: session} do
    assert :ok = Eval.detach(session)
    assert Eval.attached(session) == nil
    assert [{_sandbox, _value}] = sandboxes(runtime, session)
  end

  test "the node a host sends the session home to is the one the tool evaluates on",
       %{runtime: runtime, session: session, tmp_dir: tmp_dir} do
    :ok = Eval.detach(session)
    [{sandbox, _value}] = sandboxes(runtime, session)

    context = %{
      cwd: tmp_dir,
      session_id: Session.id(session),
      call_id: "call-1",
      session: session,
      supervisor: runtime
    }

    assert {:ok, output} = Tools.Eval.run(%{"code" => "1 + 1"}, context)
    assert output =~ "2"
    assert [{^sandbox, _value}] = sandboxes(runtime, session)
  end
end
