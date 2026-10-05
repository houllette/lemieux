defmodule Lemieux.Subagent.DelegateTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Tool

  # This description and this schema are the *only* thing a model is ever told
  # about delegating: the default system prompt says nothing, and a workspace's
  # instructions say nothing unless somebody wrote it there. A session on
  # 2026-09-18 answered "tell me about this repo" by spawning a scout rather
  # than reading anything, which is what a capability with no threshold in its
  # description invites.
  describe "what the model is told about delegating" do
    defp delegate_tool do
      Delegate.new(
        [
          Definition.new(
            id: "scout",
            description: "Reads one subsystem",
            system_prompt: "Return file and line evidence.",
            model: "test:child",
            tools: [Lemieux.Tools.Read],
            max_cost_usd: 0.1
          )
        ],
        snapshot: %{"git_commit" => "abc123"},
        max_cost_usd: 0.5
      )
    end

    test "the description says when the tool is not worth it, not only what it does" do
      description = Tool.description(delegate_tool())

      # What it is.
      assert description =~ "read-only investigations"
      assert description =~ "Available definitions: scout: Reads one subsystem"

      # When it earns its keep, and when it does not. The second half is the
      # one that was missing.
      assert description =~ "do not depend on each other"
      assert description =~ "read it yourself"

      # Measured, not asserted: `eval/corpus/investigators-v1` found the same
      # answers for about five times the tokens.
      assert description =~ "five times the tokens"
    end

    # A child receives the brief and nothing else, so an undescribed field is
    # a field the model fills in by guessing.
    test "every brief field carries a description" do
      properties =
        delegate_tool()
        |> Tool.schema()
        |> get_in(["properties", "tasks", "items", "properties"])

      for {name, property} <- properties do
        assert is_binary(property["description"]),
               "the delegate brief's #{name} has no description"
      end

      assert properties["objective"]["description"] =~ "has not seen this conversation"
    end
  end

  @tag :tmp_dir
  test "a configured parent model delegates through one foreground tool", context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    child =
      Scripted.new(
        [
          [
            {:text_delta,
             JSON.encode!(%{
               "answer" => "Session owns cancellation.",
               "findings" => [],
               "artifacts" => [],
               "uncertainties" => [],
               "coverage" => %{"searched" => ["lib/lemieux/session.ex"], "skipped" => []}
             })},
            {:usage, %{"input_tokens" => 8, "output_tokens" => 3, "cost_usd" => 0.01}},
            {:done, :stop}
          ]
        ],
        estimated_cost_usd: 0.01
      )

    parent =
      Scripted.new([
        [
          {:tool_call,
           %{
             id: "delegate-1",
             name: "delegate",
             arguments: %{
               "tasks" => [
                 %{
                   "definition_id" => "scout",
                   "objective" => "Find who owns cancellation",
                   "expected_evidence" => ["file and line"]
                 }
               ]
             }
           }},
          {:done, :tool_calls}
        ],
        fn request ->
          result = request.entries |> List.last() |> Map.fetch!(:payload) |> Map.fetch!("output")

          if String.contains?(result, "Session owns cancellation.") do
            [{:text_delta, "I verified the cancellation owner."}, {:done, :stop}]
          else
            [{:error, :missing_child_result}]
          end
        end
      ])

    definition =
      Definition.new(
        id: "scout",
        description: "Reads one subsystem",
        system_prompt: "Return file and line evidence.",
        model: "test:child",
        tools: [Lemieux.Tools.Read],
        max_cost_usd: 0.1
      )

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: parent,
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: [
          Delegate.new([definition],
            snapshot: %{"git_commit" => "abc123"},
            max_cost_usd: 0.5,
            providers: %{"scout" => child}
          )
        ],
        subscriber: self()
      )

    assert :ok = Session.prompt(session, "Investigate before answering")
    assert_receive {:lemieux, _id, {:finished, :stop}}, 5_000

    [first_request, second_request] = Scripted.requests(parent)
    assert [delegate_tool] = first_request.tools
    assert Tool.name(delegate_tool) == "delegate"

    # The definition id is an enum of what the parent may actually use, so a
    # model cannot lose a turn guessing a name that does not exist.
    schema = Tool.schema(delegate_tool)

    assert get_in(schema, ["properties", "tasks", "items", "properties", "definition_id", "enum"]) ==
             ["scout"]

    delegate_result = second_request.entries |> List.last() |> Map.fetch!(:payload)
    assert delegate_result["name"] == "delegate"
    assert delegate_result["error"] == false
    assert JSON.decode!(delegate_result["output"])["status"] == "ok"

    [child_request] = Scripted.requests(child)
    assert child_request.system =~ "The parent owns the decision and every write"
    assert Enum.map(child_request.tools, &Tool.name/1) == ["read"]

    # A finished parent going away ends the group as a shutdown, not a crash:
    # every completed delegation used to log an error report at this point.
    [group] =
      Registry.select(Lemieux.Supervisor.registry(runtime), [
        {{{:subagent_group, :_}, :"$1", :_}, [], [:"$1"]}
      ])

    monitor = Process.monitor(group)
    :ok = GenServer.stop(session)

    assert_receive {:DOWN, ^monitor, :process, ^group, {:shutdown, {:parent_down, _reason}}},
                   5_000
  end

  # The mistake is named where it is made — at construction, by the host —
  # rather than three turns later by a child that could not be admitted.
  test "definitions require an explicit snapshot and tree budget" do
    definition =
      Definition.new(
        id: "scout",
        description: "Reads code",
        system_prompt: "Return evidence",
        model: "test:child",
        tools: [],
        max_cost_usd: 0.1
      )

    assert_raise ArgumentError, ~r/:snapshot/, fn -> Delegate.new([definition], []) end

    assert_raise ArgumentError, ~r/:max_cost_usd/, fn ->
      Delegate.new([definition], snapshot: %{"git_commit" => "abc123"})
    end
  end

  # What only the session knows is read at call time, so the same struct is
  # good in any session it is handed to — and a session that was never given
  # one has no delegation, however it was started.
  @tag :tmp_dir
  test "a session not handed the tool cannot delegate", context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: []
      )

    refute Enum.any?(Session.tools(session), &(Tool.name(&1) == "delegate"))
  end
end
