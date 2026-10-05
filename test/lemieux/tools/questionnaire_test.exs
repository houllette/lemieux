defmodule Lemieux.Tools.QuestionnaireTest do
  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.AskUser
  alias Lemieux.Tools.AskUser.Questionnaire

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir)}
  end

  defp question(id),
    do: %{
      "id" => id,
      "question" => "Select features",
      "multiple" => true,
      "options" => [
        %{"id" => "a", "label" => "First", "preview" => "Example one"},
        %{"id" => "b", "label" => "Second"}
      ]
    }

  defp start(context, questions, opts \\ []) do
    provider =
      Scripted.new([
        [
          {:tool_call, %{id: "batch", name: "ask_user", arguments: %{"questions" => questions}}},
          {:done, :tool_calls}
        ],
        [{:text_delta, "received"}, {:done, :stop}]
      ])

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          model: "test:questionnaire",
          store: context.store,
          subscriber: self(),
          tools: [AskUser]
        ] ++ opts
      )

    :ok = Session.prompt(session, "ask")
    {session, provider, Session.id(session)}
  end

  test "batch answers preserve stable ids, notes and identical text/structured semantics",
       context do
    {session, provider, id} = start(context, [question("one"), question("two")])
    assert_receive {:lemieux, ^id, {:question, %{call_id: "batch", options: options} = first}}
    assert hd(options).preview == "Example one"
    assert length(first.questions) == 2
    {conversation, effects} = Conversation.event(Conversation.new(), {:question, first})

    assert Enum.any?(effects, fn
             {:say, text} -> text =~ "Example one"
             _ -> false
           end)

    assert {conversation, [_next_question]} =
             Conversation.input(conversation, "1,2 | include both")

    assert {_, [{:answer, "batch", %{"answers" => [_first, _second]}}]} =
             Conversation.input(conversation, "1,2 | include both")

    assert :ok =
             Session.answer(session, "batch", %{
               "answers" => [
                 "1,2 | include both",
                 %{"selected" => ["a", "b"], "notes" => "include both"}
               ]
             })

    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_first, request] = Scripted.requests(provider)
    result = Enum.find(request.entries, &(&1.type == :tool_result))
    data = result.payload["structured_content"]
    assert data["status"] == "answered"
    [first, second] = data["answers"]
    assert first["question_id"] == "one"
    assert second["question_id"] == "two"
    assert Map.delete(first, "question_id") == Map.delete(second, "question_id")
  end

  test "each batch question can carry its own diagram into the TUI payload", context do
    diagram = "input ─▶ parser\n           │\n           ▼\n         output"
    questions = [Map.put(question("one"), "diagram", diagram), question("two")]
    {_session, _provider, id} = start(context, questions)
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert hd(payload.questions).diagram == diagram
    assert List.last(payload.questions).diagram == nil

    {_conversation, effects} = Conversation.event(Conversation.new(), {:question, payload})

    assert Enum.any?(effects, fn
             {:say, text} -> String.contains?(text, diagram)
             _other -> false
           end)
  end

  test "suggestion diagrams stay paired with their options and option notes are validated",
       context do
    first = question("one") |> Map.delete("multiple")
    [option | rest] = first["options"]
    first = put_in(first, ["options"], [Map.put(option, "diagram", "input → first") | rest])
    {_session, _provider, id} = start(context, [first])
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert hd(payload.options).diagram == "input → first"
    assert List.last(payload.options).diagram == nil

    assert %{"option_notes" => %{"a" => "Keep the existing path"}} =
             Questionnaire.normalize(
               {:ok,
                %{"selected" => ["a"], "option_notes" => %{"a" => "Keep the existing path"}}},
               first
             )

    assert %{"status" => "invalid"} =
             Questionnaire.normalize(
               {:ok, %{"selected" => ["a"], "option_notes" => %{"b" => "Not selected"}}},
               first
             )

    assert {:error, _} =
             Questionnaire.run(
               [
                 put_in(
                   first,
                   ["options", Access.at(0), "diagram"],
                   "bad\n" <> String.duplicate("x", 73)
                 )
               ],
               %{}
             )
  end

  test "refusal stops the batch without inventing remaining answers", context do
    {session, provider, id} = start(context, [question("one"), question("two")])
    assert_receive {:lemieux, ^id, {:question, first}}
    {conversation, _} = Conversation.event(Conversation.new(), {:question, first})

    assert {_, [{:answer, "batch", %{"status" => "declined"}}]} =
             Conversation.input(conversation, "/decline")

    :ok = Session.answer(session, "batch", %{"status" => "declined"})
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    refute_received {:lemieux, ^id, {:question, %{call_id: "batch:two"}}}
    [_, request] = Scripted.requests(provider)
    data = Enum.find(request.entries, &(&1.type == :tool_result)).payload["structured_content"]
    assert data["answers"] == [%{"question_id" => "one", "status" => "declined"}]
  end

  test "timeouts remain distinct from refusals", context do
    {_session, provider, id} = start(context, [question("one")], approval_timeout: 10)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_, request] = Scripted.requests(provider)
    data = Enum.find(request.entries, &(&1.type == :tool_result)).payload["structured_content"]
    assert data["answers"] == [%{"question_id" => "one", "status" => "timed_out"}]
  end

  test "validation tells the model which field to repair" do
    assert {:error, missing_question} =
             Questionnaire.run([%{"id" => "one", "options" => []}], %{})

    assert missing_question =~ "questions[1].question is required"

    assert {:error, bad_options} =
             Questionnaire.run(
               [%{"id" => "one", "question" => "Which?", "options" => [%{"label" => "A"}]}],
               %{}
             )

    assert bad_options =~ "questions[1].options needs 2–6"
  end

  test "missing stable ids are assigned before asking", context do
    questions = [
      %{
        "question" => "Which route?",
        "options" => [%{"label" => "Direct"}, %{"label" => "Gateway"}]
      }
    ]

    {session, provider, id} = start(context, questions)
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert payload.question_id == "question_1"
    assert Enum.map(payload.options, & &1.id) == ["option_1", "option_2"]

    assert :ok = Session.answer(session, "batch", %{"answers" => [%{"selected" => ["option_2"]}]})
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_first, request] = Scripted.requests(provider)
    result = Enum.find(request.entries, &(&1.type == :tool_result))

    assert result.payload["structured_content"]["answers"] |> hd() |> Map.get("question_id") ==
             "question_1"
  end

  test "generated ids avoid explicitly supplied ids", context do
    questions = [
      %{
        "question" => "First?",
        "options" => [%{"label" => "A"}, %{"id" => "option_1", "label" => "B"}]
      },
      %{
        "id" => "question_1",
        "question" => "Second?",
        "type" => "text"
      }
    ]

    {_session, _provider, id} = start(context, questions)
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert Enum.map(payload.questions, & &1.question_id) == ["question_1_2", "question_1"]
    assert Enum.map(hd(payload.questions).options, & &1.id) == ["option_1_2", "option_1"]
  end

  test "invalid batches are rejected before parking and malformed answers never select defaults" do
    assert {:error, _} = Questionnaire.run([question("same"), question("same")], %{})
    assert {:error, _} = Questionnaire.run([Map.delete(question("one"), "options")], %{})

    assert {:error, _} =
             Questionnaire.run(
               [Map.put(question("one"), "diagram", Enum.join(List.duplicate("node", 6), "\n"))],
               %{}
             )

    assert {:error, _} =
             Questionnaire.run(
               [put_in(question("one"), ["options", Access.at(1), "label"], "Other")],
               %{}
             )

    assert %{"status" => "invalid"} =
             Questionnaire.normalize({:ok, %{"selected" => ["unknown"]}}, question("one"))

    assert %{"status" => "invalid"} = Questionnaire.normalize({:ok, ""}, question("one"))

    assert %{"status" => "unavailable"} =
             Questionnaire.normalize({:ok, %{"status" => "unavailable"}}, question("one"))
  end

  test "ranking, text, and number questions validate and normalize without guessing" do
    ranking = question("priority") |> Map.delete("multiple") |> Map.put("type", "ranking")
    text = %{"id" => "why", "question" => "Why?", "type" => "text"}
    number = %{"id" => "days", "question" => "How many days?", "type" => "number"}

    assert Questionnaire.schema()["items"]["properties"]["type"]["enum"] ==
             ~w(single_choice multi_select ranking text number)

    assert %{"status" => "answered", "kind" => "ranking", "ranked" => ["b", "a"]} =
             Questionnaire.normalize({:ok, "2,1"}, ranking)

    assert %{"status" => "invalid"} = Questionnaire.normalize({:ok, "1,1"}, ranking)
    assert %{"status" => "invalid"} = Questionnaire.normalize({:ok, "1"}, ranking)
    assert %{"status" => "invalid"} = Questionnaire.normalize({:ok, "Do B first"}, ranking)

    assert %{"status" => "answered", "kind" => "ranking", "notes" => "Start here"} =
             Questionnaire.normalize(
               {:ok, %{"ranked" => ["b", "a"], "notes" => "Start here"}},
               ranking
             )

    assert %{"status" => "answered", "kind" => "selection", "selected" => []} =
             Questionnaire.normalize(
               {:ok, "/none"},
               question("features") |> Map.delete("multiple") |> Map.put("type", "multi_select")
             )

    assert %{"status" => "answered", "kind" => "text", "text" => "Because it is faster"} =
             Questionnaire.normalize({:ok, "Because it is faster"}, text)

    assert %{"status" => "answered", "kind" => "number", "number" => "2.5"} =
             Questionnaire.normalize({:ok, "2.5"}, number)

    assert %{"status" => "answered", "number" => ".5e2"} =
             Questionnaire.normalize({:ok, ".5e2"}, number)

    assert %{"status" => "invalid"} = Questionnaire.normalize({:ok, "soon"}, number)

    assert %{"status" => "invalid"} =
             Questionnaire.normalize({:ok, %{"text" => "soon"}}, number)

    assert {:error, _} = Questionnaire.run([Map.put(ranking, "options", [])], %{})
    assert {:error, _} = Questionnaire.run([Map.put(text, "options", ranking["options"])], %{})
    assert {:error, _} = Questionnaire.run([Map.put(number, "type", "unknown")], %{})
  end

  test "mixed question types deliver structured answers to the model", context do
    ranking = question("priority") |> Map.delete("multiple") |> Map.put("type", "ranking")
    multi = question("features") |> Map.delete("multiple") |> Map.put("type", "multi_select")
    number = %{"id" => "days", "question" => "How many days?", "type" => "number"}
    {session, provider, id} = start(context, [ranking, multi, number])
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert Enum.map(payload.questions, & &1.type) == ~w(ranking multi_select number)

    assert :ok =
             Session.answer(session, "batch", %{
               "answers" => [
                 %{"ranked" => ["b", "a"]},
                 %{"selected" => ["a", "b"]},
                 %{"number" => "3"}
               ]
             })

    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_, request] = Scripted.requests(provider)
    result = Enum.find(request.entries, &(&1.type == :tool_result))

    assert result.payload["structured_content"]["answers"] == [
             %{
               "question_id" => "priority",
               "status" => "answered",
               "kind" => "ranking",
               "ranked" => ["b", "a"]
             },
             %{
               "question_id" => "features",
               "status" => "answered",
               "kind" => "selection",
               "selected" => ["a", "b"]
             },
             %{
               "question_id" => "days",
               "status" => "answered",
               "kind" => "number",
               "number" => "3"
             }
           ]
  end
end
