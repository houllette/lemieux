defmodule Lemieux.RepositoryContext.SessionTest do
  use ExUnit.Case, async: true
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.RepositoryContext.Elixir, as: Indexer
  alias Lemieux.RepositoryContext.Index
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  test "an ordinary session invokes the configured tool and retains source evidence", %{
    tmp_dir: root
  } do
    File.write!(
      Path.join(root, "example.ex"),
      "defmodule Example do\n  def hello(), do: :ok\nend\n"
    )

    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    {:ok, index, _metrics} = Indexer.build(Lemieux.Environment.local(), root, ["example.ex"])

    {:ok, harness} =
      Harness.assemble(Harness.new(), [
        {Lemieux.Extensions.RepositoryContext,
         repositories: [%{id: "app", backend: {Index, index}, paths: ["example.ex"]}]}
      ])

    provider =
      Scripted.new([
        [
          {:tool_call,
           %{
             id: "context",
             name: "repository_context",
             arguments: %{"operation" => "definitions", "query" => "hello"}
           }},
          {:done, :tool_calls}
        ],
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(Path.join(root, "sessions")),
        provider: provider,
        model: "test:repository-context",
        harness: harness,
        cwd: root,
        subscriber: self()
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "Find hello")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [first, second] = Scripted.requests(provider)
    assert Enum.any?(first.tools, &(Lemieux.Tool.name(&1) == "repository_context"))
    result = Enum.find(second.entries, &(&1.type == :tool_result))
    assert result.payload["output"] =~ "app:example.ex:2"

    assert result.payload["structured_content"]["items"] |> hd() |> Map.fetch!("freshness") ==
             "verified"

    assert Enum.any?(Session.snapshot(session).entries, &(&1.type == :request))

    assert :ok =
             DynamicSupervisor.terminate_child(
               Lemieux.Supervisor.session_supervisor(runtime),
               session
             )
  end
end
