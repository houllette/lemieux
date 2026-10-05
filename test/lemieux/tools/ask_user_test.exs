defmodule Lemieux.Tools.AskUserTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools
  alias Lemieux.Tools.AskUser

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_ask_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp ask_call(question, arguments),
    do: %{
      id: "q1",
      name: "ask_user",
      arguments: Map.put(arguments, "question", question)
    }

  defp start_asking(context, question, opts \\ []) do
    {arguments, opts} =
      Keyword.pop(opts, :arguments, %{
        "options" => [%{"label" => "Postgres"}, %{"label" => "SQLite"}]
      })

    provider =
      Scripted.new([
        [{:tool_call, ask_call(question, arguments)}, {:done, :tool_calls}],
        [{:text_delta, "thanks"}, {:done, :stop}]
      ])

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          tools: [AskUser]
        ]
        |> Keyword.merge(opts)
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "do the thing")

    {session, provider, id}
  end

  describe "the tool" do
    # It is deliberately not in the default set: a session with nobody attached
    # cannot answer, and every tool is a permanent tax on the prompt.
    test "is not one of the tools a session gets by default" do
      refute AskUser in Tools.default()
    end

    test "describes itself well enough to be called" do
      assert AskUser.name() == "ask_user"
      assert is_binary(AskUser.description())
      assert AskUser.description() =~ "ids help interpret answers"
      assert AskUser.description() =~ "Never include Other"

      assert %{
               "properties" => %{
                 "question" => _,
                 "diagram" => %{"type" => "string"},
                 "options" => %{"minItems" => 2, "maxItems" => 6}
               }
             } = AskUser.schema()
    end

    test "question forms are mutually exclusive at runtime without a schema combinator" do
      refute Map.has_key?(AskUser.schema(), "oneOf")

      assert {:error, "ask_user accepts question or questions, not both"} =
               AskUser.run(%{"question" => "Which?", "questions" => []}, %{})

      assert {:error, message} = AskUser.run(%{}, %{})
      assert message =~ "ask_user needs a question"
    end
  end

  describe "asking" do
    test "the question reaches the subscriber, and the turn waits", context do
      {session, provider, id} = start_asking(context, "which database?")

      assert_receive {:lemieux, ^id, {:question, question}}
      assert question.question == "which database?"
      assert question.call_id == "q1"

      # Nothing has moved on: the model is waiting for the answer.
      assert length(Scripted.requests(provider)) == 1
      assert Session.snapshot(session).status == :busy
    end

    test "required choices reach interactive consumers with labels and descriptions", context do
      options = [
        %{"label" => "Postgres", "description" => "Use the existing database"},
        %{"label" => "SQLite"}
      ]

      {session, _provider, id} =
        start_asking(context, "which database?", arguments: %{"options" => options})

      assert_receive {:lemieux, ^id, {:question, question}}

      assert question.options == [
               %{label: "Postgres", description: "Use the existing database", diagram: nil},
               %{label: "SQLite", description: nil, diagram: nil}
             ]

      assert question.ask_user

      assert [pending] = Session.snapshot(session).pending
      assert pending.payload == question
    end

    test "an optional text diagram reaches the parked question intact", context do
      diagram = "request ──▶ cache\n              │\n              ▼\n           provider"

      {_session, _provider, id} =
        start_asking(context, "Which route?",
          arguments: %{
            "options" => [%{"label" => "Direct"}, %{"label" => "Cached"}],
            "diagram" => diagram
          }
        )

      assert_receive {:lemieux, ^id, {:question, %{diagram: ^diagram}}}
    end

    test "each suggested answer can carry a different diagram", context do
      {_session, _provider, id} =
        start_asking(context, "Which route?",
          arguments: %{
            "options" => [
              %{"label" => "Direct", "diagram" => "client → provider"},
              %{"label" => "Cached", "diagram" => "client → cache → provider"}
            ]
          }
        )

      assert_receive {:lemieux, ^id, {:question, %{options: [direct, cached]}}}
      assert direct.diagram == "client → provider"
      assert cached.diagram == "client → cache → provider"
    end

    test "the answer becomes the tool result the model reads", context do
      {session, provider, id} = start_asking(context, "which database?")
      assert_receive {:lemieux, ^id, {:question, _question}}

      assert :ok = Session.answer(session, "q1", "postgres, please")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "postgres, please"
      refute payload["error"]
    end

    test "attention observes questions even when no policy hook parked them", context do
      parent = self()

      attention = fn payload, _hook_context ->
        send(parent, {:attention, payload})
      end

      {session, _provider, id} =
        start_asking(context, "which database?", hooks: [attention: attention])

      assert_receive {:attention, %{state: :waiting, call_id: "q1", kind: :question}}
      assert :ok = Session.answer(session, "q1", "postgres")
      assert_receive {:attention, %{state: :working}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "a parked question is visible in a snapshot", context do
      {session, _provider, id} = start_asking(context, "which database?")
      assert_receive {:lemieux, ^id, {:question, _question}}

      assert [pending] = Session.snapshot(session).pending
      assert pending.kind == :question
    end

    # Otherwise an unattended session hangs on a question nobody will ever see.
    test "an unanswered question times out, and the model is told to carry on",
         context do
      {_session, provider, id} = start_asking(context, "which database?", approval_timeout: 30)

      # The timeout is thirty milliseconds; the wait is for the loop to notice
      # it, write the denial and finish under a full suite's load.
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] =~ "nobody answered"
      assert payload["error"]
    end

    test "answering a question nobody asked says so", context do
      {session, _provider, id} = start_asking(context, "which database?")
      assert_receive {:lemieux, ^id, {:question, _question}}

      assert {:error, :unknown_call} = Session.answer(session, "nope", "hello")
    end

    test "a question with no text is an error rather than an empty prompt", context do
      provider =
        Scripted.new([
          [
            {:tool_call, %{id: "q1", name: "ask_user", arguments: %{}}},
            {:done, :tool_calls}
          ],
          [{:text_delta, "ok"}, {:done, :stop}]
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          tools: [AskUser]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["error"]
    end

    test "a question without suggested answers is rejected", context do
      assert {:error, reason} = AskUser.run(%{"question" => "Choose?"}, context)
      assert reason =~ "two to six suggested answers"

      assert {:error, _reason} =
               AskUser.run(
                 %{
                   "question" => "Choose?",
                   "options" => [%{"label" => "Yes"}, %{"label" => "Other"}]
                 },
                 context
               )
    end

    test "a single typed question works without suggestions and returns a structured answer",
         context do
      {session, provider, id} =
        start_asking(context, "How many days?", arguments: %{"type" => "number"})

      assert_receive {:lemieux, ^id, {:question, question}}
      assert question.questionnaire
      assert question.type == "number"
      assert question.options == []

      :ok = Session.answer(session, "q1", %{"answers" => [%{"number" => "2.5"}]})
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      [_, request] = Scripted.requests(provider)
      result = Enum.find(request.entries, &(&1.type == :tool_result))

      assert result.payload["structured_content"]["answers"] == [
               %{
                 "question_id" => "answer",
                 "status" => "answered",
                 "kind" => "number",
                 "number" => "2.5"
               }
             ]
    end

    test "an oversized diagram is rejected before asking", context do
      diagram = Enum.join(List.duplicate("node", 6), "\n")

      assert {:error, reason} =
               AskUser.run(
                 %{
                   "question" => "Which route?",
                   "options" => [%{"label" => "Direct"}, %{"label" => "Cached"}],
                   "diagram" => diagram
                 },
                 context
               )

      assert reason =~ "diagram"
    end
  end
end
