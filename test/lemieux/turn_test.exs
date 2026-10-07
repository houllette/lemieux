defmodule Lemieux.TurnTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error.API.Request, as: RequestError
  alias ReqLLM.Error.API.Stream, as: StreamError

  alias Lemieux.Turn

  # Not one process is started in this file, and that is the point: the rules
  # about what a stream of provider events means are decided here, where a
  # failure names the rule it broke rather than timing out.

  defp fold(events) do
    Enum.reduce(events, {Turn.new("assistant-1"), []}, fn event, {turn, effects} ->
      {turn, new_effects} = Turn.step(turn, event)
      {turn, effects ++ new_effects}
    end)
  end

  defp effects(events), do: events |> fold() |> elem(1)

  describe "text" do
    test "each delta is emitted as it arrives" do
      assert [
               {:emit, {:text_delta, %{id: "assistant-1", text: "he"}}},
               {:emit, {:text_delta, %{id: "assistant-1", text: "llo"}}}
               | _
             ] =
               effects([{:text_delta, "he"}, {:text_delta, "llo"}, {:done, :stop}])
    end

    test "the deltas are assembled into one assistant entry when the turn finishes" do
      effects = effects([{:text_delta, "he"}, {:text_delta, "llo"}, {:done, :stop}])

      assert {:append, {:assistant, payload, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))

      assert payload == %{"content" => [%{"type" => "text", "text" => "hello"}]}
    end

    test "a turn with no text at all still finishes" do
      assert effects([{:done, :stop}]) == [{:finished, :stop}]
    end
  end

  describe "thinking" do
    test "deltas are emitted separately from text and kept out of the text content" do
      effects =
        effects([
          {:thinking_delta, "hmm"},
          {:text_delta, "hi"},
          {:done, :stop}
        ])

      assert {:emit, {:thinking_delta, %{id: "assistant-1", text: "hmm"}}} in effects

      assert {:append, {:assistant, payload, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))

      assert payload == %{
               "content" => [
                 %{"type" => "thinking", "text" => "hmm"},
                 %{"type" => "text", "text" => "hi"}
               ]
             }
    end
  end

  describe "usage" do
    test "rides along on the assistant entry rather than becoming an entry of its own" do
      usage = %{"input_tokens" => 10, "output_tokens" => 2}

      effects = effects([{:text_delta, "hi"}, {:usage, usage}, {:done, :stop}])

      assert {:append, {:assistant, _payload, ^usage}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))
    end

    test "is emitted too, so a host can show a running total without reading the store" do
      usage = %{"input_tokens" => 10, "output_tokens" => 2}

      assert {:emit, {:usage, ^usage}} =
               [{:usage, usage}, {:done, :stop}]
               |> effects()
               |> Enum.find(&match?({:emit, {:usage, _}}, &1))
    end
  end

  describe "a provider-assembled message" do
    test "replaces the content assembled from deltas" do
      # The deltas are what the user watched; the assembled message is what
      # the provider will accept back on the next request. When a provider
      # signs its thinking blocks, only the second one continues the
      # conversation, so it wins.
      signed = %{
        "content" => [
          %{"type" => "thinking", "text" => "hmm", "signature" => "sig"},
          %{"type" => "text", "text" => "hello"}
        ]
      }

      effects =
        effects([
          {:thinking_delta, "hmm"},
          {:text_delta, "hello"},
          {:message, signed},
          {:done, :stop}
        ])

      assert {:append, {:assistant, ^signed, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))
    end

    test "an empty assembled message does not discard streamed text" do
      effects =
        effects([
          {:text_delta, ~s({"answer":"lemieux"})},
          {:message, %{"content" => []}},
          {:done, :stop}
        ])

      assert {:append, {:assistant, payload, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))

      assert payload["content"] == [%{"type" => "text", "text" => ~s({"answer":"lemieux"})}]
    end
  end

  describe "errors" do
    test "a partial answer is persisted before the error that interrupted it" do
      effects = effects([{:text_delta, "half a th"}, {:error, :closed}])

      assert [
               {:emit, {:text_delta, %{id: "assistant-1", text: "half a th"}}},
               {:append, {:assistant, %{"content" => [%{"text" => "half a th"}]}, nil}},
               {:emit, {:error, :closed}},
               {:append, {:error, %{"reason" => reason}, nil}},
               {:finished, :error}
             ] = effects

      assert reason =~ "closed"
    end

    test "an error with nothing streamed yet appends only the error" do
      assert [
               {:emit, {:error, :nope}},
               {:append, {:error, _, nil}},
               {:finished, :error}
             ] = effects([{:error, :nope}])
    end

    # Prose cannot be classified after the fact, and every provider failure
    # ends a turn identically, so the durable entry has to carry the category
    # that tells a stalled stream from a refusal.
    test "the error entry records the failure's category beside its message" do
      stall = StreamError.exception(reason: "Stream failed: :timeout", cause: :timeout)

      assert [
               {:emit, {:error, ^stall}},
               {:append, {:error, %{"category" => "timeout"}, nil}},
               {:finished, :error}
             ] = effects([{:error, stall}])

      refused = RequestError.exception(reason: "nope", status: 403)

      assert [
               {:emit, _},
               {:append, {:error, refused_payload, nil}},
               {:finished, :error}
             ] = effects([{:error, refused}])

      # The status is the fact behind the category, for a host whose retry
      # policy needs more than "other"; a failure without one carries no key.
      assert refused_payload == %{"category" => "other", "reason" => "nope", "http_status" => 403}

      assert [_emit, {:append, {:error, stall_payload, nil}}, _finished] =
               effects([{:error, stall}])

      refute Map.has_key?(stall_payload, "http_status")
    end
  end

  describe "tool calls" do
    defp call(id, name, arguments \\ %{}) do
      %{id: id, name: name, arguments: arguments}
    end

    test "a call is emitted as it is seen, so a host can show the work starting" do
      effects = effects([{:tool_call, call("1", "read", %{"path" => "a"})}, {:done, :tool_calls}])

      assert {:emit, {:tool_call, %{name: "read"}}} =
               Enum.find(effects, &match?({:emit, {:tool_call, _}}, &1))
    end

    test "the calls ride on the assistant entry, in the order the model made them" do
      effects =
        effects([
          {:text_delta, "let me look"},
          {:tool_call, call("1", "read", %{"path" => "a"})},
          {:tool_call, call("2", "read", %{"path" => "b"})},
          {:done, :tool_calls}
        ])

      assert {:append, {:assistant, payload, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))

      assert payload == %{
               "content" => [%{"type" => "text", "text" => "let me look"}],
               "tool_calls" => [
                 %{"id" => "1", "name" => "read", "arguments" => %{"path" => "a"}},
                 %{"id" => "2", "name" => "read", "arguments" => %{"path" => "b"}}
               ]
             }
    end

    test "a turn that called tools asks for them to run instead of finishing" do
      effects = effects([{:tool_call, call("1", "bash")}, {:done, :tool_calls}])

      refute Enum.any?(effects, &match?({:finished, _}, &1))
      assert {:run_tools, [%{id: "1", name: "bash"}]} = List.last(effects)
    end

    test "a turn with no calls finishes, whatever the model said its reason was" do
      effects = effects([{:text_delta, "done"}, {:done, :tool_calls}])

      assert {:finished, :tool_calls} = List.last(effects)
    end

    test "a call assembled with no arguments still runs" do
      effects = effects([{:tool_call, %{id: "1", name: "bash"}}, {:done, :tool_calls}])

      assert {:run_tools, [%{arguments: %{}} = call]} = List.last(effects)
      refute Map.has_key?(call, :argument_error)
    end

    # The output limit ends a response wherever it falls, and a model writing
    # a large file is inside the last call's arguments when it does. What
    # arrives is a call with no usable arguments: run as it stood, `write`
    # answered "needs a path and content", the model sent the same oversized
    # call again, and the repeat guard ended the prompt (live, 2026-10-07).
    test "the call the output limit cut off is marked so, and the calls before it are not" do
      effects =
        effects([
          {:tool_call, call("1", "read", %{"path" => "a"})},
          {:tool_call, %{id: "2", name: "write", arguments: %{}, argument_error: :lost}},
          {:done, :length}
        ])

      assert {:run_tools, [first, cut]} = List.last(effects)
      refute Map.has_key?(first, :argument_error)
      assert cut.argument_error == :output_limit
    end

    test "a last call with no arguments in a cut-off response is taken as cut off" do
      effects = effects([{:tool_call, %{id: "1", name: "write"}}, {:done, :length}])

      assert {:run_tools, [%{argument_error: :output_limit}]} = List.last(effects)
    end

    test "a last call whose arguments arrived whole still runs after a cut-off" do
      whole = call("1", "write", %{"path" => "a", "content" => "x"})
      effects = effects([{:tool_call, whole}, {:done, :length}])

      assert {:run_tools, [last]} = List.last(effects)
      refute Map.has_key?(last, :argument_error)
    end

    test "an interrupted turn keeps what was said but drops calls nothing will answer" do
      # The calls were announced but the turn is ending, so none of them runs.
      # An assistant entry that carried them would be a conversation with
      # unanswered calls, which no provider accepts back.
      effects =
        effects([{:text_delta, "running it"}, {:tool_call, call("1", "bash")}, {:error, :closed}])

      assert {:append, {:assistant, payload, nil}} =
               Enum.find(effects, &match?({:append, {:assistant, _, _}}, &1))

      assert payload["content"] == [%{"type" => "text", "text" => "running it"}]
      refute Map.has_key?(payload, "tool_calls")
      # A record of what arrived, never sent back as though it were an answer.
      assert payload["partial"] == true
      assert {:finished, :error} = List.last(effects)
    end

    test "an interrupted turn that only called tools leaves no assistant entry" do
      effects = effects([{:tool_call, call("1", "bash")}, {:error, :closed}])

      refute Enum.any?(effects, &match?({:append, {:assistant, _, _}}, &1))
      assert Enum.any?(effects, &match?({:append, {:error, _payload, nil}}, &1))
    end
  end

  # A model writing a 35 KB file is silent on every other channel for
  # minutes; these are the events a front end draws in the meantime.
  describe "a tool call being composed" do
    test "is announced by name, grows by fragment, and is never the call" do
      turn = Turn.new("entry-1")

      {turn, [{:emit, opened}]} = Turn.step(turn, {:tool_call_delta, %{index: 0, name: "write"}})
      assert opened == {:tool_call_delta, %{id: "entry-1", name: "write", bytes: 0, head: ""}}

      {turn, [{:emit, grown}]} =
        Turn.step(
          turn,
          {:tool_call_delta, %{index: 0, fragment: ~s({"path": "tmp/a.md", "content": "one)}}
        )

      assert {:tool_call_delta, %{name: "write", bytes: 36, head: head}} = grown
      assert head == ~s({"path": "tmp/a.md", "content": "one)

      {turn, [{:emit, more}]} =
        Turn.step(turn, {:tool_call_delta, %{index: 0, fragment: String.duplicate("x", 500)}})

      assert {:tool_call_delta, %{bytes: 536, head: head}} = more
      # The head is bounded: enough for a path, never the file.
      assert byte_size(head) == 240

      assert Turn.progressed?(turn)
      assert turn.tool_calls == []
    end

    test "a new index is the next call" do
      turn = Turn.new("entry-1")
      {turn, _} = Turn.step(turn, {:tool_call_delta, %{index: 0, name: "read"}})
      {turn, _} = Turn.step(turn, {:tool_call_delta, %{index: 0, fragment: "abc"}})
      {_turn, [{:emit, event}]} = Turn.step(turn, {:tool_call_delta, %{index: 1, name: "write"}})

      assert {:tool_call_delta, %{name: "write", bytes: 0, head: ""}} = event
    end

    test "a fragment with no index or name grows the current call" do
      turn = Turn.new("entry-1")
      {turn, _} = Turn.step(turn, {:tool_call_delta, %{name: "bash"}})

      {_turn, [{:emit, event}]} =
        Turn.step(turn, {:tool_call_delta, %{fragment: ~s({"command":)}})

      assert {:tool_call_delta, %{name: "bash", bytes: 11}} = event
    end
  end

  describe "status" do
    test "a turn is streaming until it is finished" do
      {turn, _} = fold([{:text_delta, "hi"}])
      assert turn.status == :streaming

      {turn, _} = fold([{:text_delta, "hi"}, {:done, :stop}])
      assert turn.status == :done
      assert turn.stop_reason == :stop
    end

    test "events after the terminal one are ignored rather than reopening the turn" do
      {turn, _} = fold([{:done, :stop}])
      assert {^turn, []} = Turn.step(turn, {:text_delta, "late"})
    end
  end
end
