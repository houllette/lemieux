defmodule Lemieux.TestingTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Testing

  @moduletag :tmp_dir

  test "captures observable session behavior without consuming an existing subscriber", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([Scripted.complete("hello", fragments: ["hel", "lo"])]),
        store: JSONL.new(dir),
        model: "test:model",
        tools: [],
        subscriber: self()
      )

    assert {:ok, result} = Testing.prompt(session, "say hello")
    assert Enum.any?(result.events, &match?({:text_delta, %{text: "hel"}}, &1))
    assert result.stop_reason == :stop
    assert Enum.any?(result.entries, &match?(%Entry{type: :assistant}, &1))
    assert %Entry{type: :run_evidence} = List.last(result.entries)

    assert_receive {:lemieux, _, {:finished, :stop}}
  end
end
