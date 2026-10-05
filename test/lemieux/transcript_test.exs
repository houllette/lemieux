defmodule Lemieux.TranscriptTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    entries = [
      Entry.new(:user, %{"text" => "one"}),
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "first"}]}),
      Entry.new(:user, %{"text" => "two"}),
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "second"}]})
    ]

    :ok = Store.append(store, "source", entries)

    %{store: store, entries: entries}
  end

  describe "fork/3" do
    test "copies the history up to and including the named entry", context do
      at = Enum.at(context.entries, 1).id

      assert {:ok, forked} = Transcript.fork(context.store, "source", at)
      assert {:ok, entries} = Store.read(context.store, forked)

      assert Enum.map(entries, & &1.type) == [:user, :assistant, :fork]
      assert Enum.map(entries, & &1.payload["text"]) |> Enum.take(1) == ["one"]
    end

    test "a fork with no cut point carries the whole history", context do
      assert {:ok, forked} = Transcript.fork(context.store, "source")
      assert {:ok, entries} = Store.read(context.store, forked)

      assert Enum.map(entries, & &1.type) == [:user, :assistant, :user, :assistant, :fork]
    end

    # The copied entries keep their ids, which is what makes shared ancestry
    # visible: two transcripts holding the same entry id hold the same event.
    test "the copied entries are the originals, not lookalikes", context do
      assert {:ok, forked} = Transcript.fork(context.store, "source")
      assert {:ok, copied} = Store.read(context.store, forked)

      assert copied |> Enum.take(4) == context.entries
    end

    test "it records where it came from, so a file on disk explains itself", context do
      at = Enum.at(context.entries, 1).id

      assert {:ok, forked} = Transcript.fork(context.store, "source", at)
      assert {:ok, entries} = Store.read(context.store, forked)

      assert %Entry{type: :fork, payload: payload} = List.last(entries)
      assert payload["from"] == "source"
      assert payload["at"] == at
    end

    test "the marker continues the chain rather than starting a second one", context do
      assert {:ok, forked} = Transcript.fork(context.store, "source")
      assert {:ok, entries} = Store.read(context.store, forked)

      marker = List.last(entries)

      assert marker.parent_id == Enum.at(context.entries, -1).id
    end

    test "the marker is numbered after the entries it follows", context do
      assert {:ok, forked} = Transcript.fork(context.store, "source")
      assert {:ok, entries} = Store.read(context.store, forked)

      assert List.last(entries).seq == length(context.entries)
    end

    test "the source is left exactly as it was", context do
      assert {:ok, _forked} = Transcript.fork(context.store, "source")

      assert {:ok, entries} = Store.read(context.store, "source")
      assert entries == context.entries
    end

    test "forking an unknown session says so", context do
      assert {:error, :not_found} = Transcript.fork(context.store, "nope")
    end

    # Silently forking the whole thing would produce a transcript that looks
    # right and is not what was asked for.
    test "a cut point that is not in the transcript is an error", context do
      assert {:error, {:unknown_entry, "nope"}} = Transcript.fork(context.store, "source", "nope")
    end

    test "each fork gets its own id", context do
      assert {:ok, first} = Transcript.fork(context.store, "source")
      assert {:ok, second} = Transcript.fork(context.store, "source")

      refute first == second
    end

    test "rejects a cut after a tool-calling assistant until every result exists", context do
      assistant =
        Entry.new(:assistant, %{
          "content" => [],
          "tool_calls" => [%{"id" => "c1", "name" => "read", "arguments" => %{}}]
        })

      :ok = Store.append(context.store, "unsafe", [assistant])

      assert {:error, {:unsafe_fork, id}} = Transcript.fork(context.store, "unsafe")
      assert id == assistant.id
      assert {:ok, _fork} = Transcript.fork(context.store, "unsafe", nil, unsafe: true)
    end

    test "supports sequence and completed-turn selectors", context do
      assert {:ok, by_seq} = Transcript.fork(context.store, "source", {:seq, 0}, unsafe: true)
      assert {:ok, by_turn} = Transcript.fork(context.store, "source", {:turn, 1})

      assert {:ok, seq_entries} = Store.read(context.store, by_seq)
      assert {:ok, turn_entries} = Store.read(context.store, by_turn)
      assert length(seq_entries) == 2
      assert length(turn_entries) == 3
    end
  end

  describe "unanswered_calls/1" do
    defp calling(id, name \\ "remote"),
      do:
        Entry.new(:assistant, %{
          "content" => [],
          "tool_calls" => [%{"id" => id, "name" => name, "arguments" => %{"n" => 1}}]
        })

    defp answering(id), do: Entry.new(:tool_result, %{"call_id" => id, "output" => "ok"})

    test "a transcript whose every wave was answered has none" do
      entries = [
        Entry.new(:user, %{"text" => "go"}),
        calling("t1"),
        answering("t1"),
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "done"}]})
      ]

      assert Transcript.unanswered_calls(entries) == []
    end

    test "a wave the session died inside is the calls nothing answered" do
      entries = [Entry.new(:user, %{"text" => "go"}), calling("t1"), calling("t2", "other")]

      entries = [
        Enum.at(entries, 0),
        Enum.at(entries, 1),
        answering("t1") | Enum.drop(entries, 2)
      ]

      assert [%{id: "t2", name: "other", arguments: %{"n" => 1}}] =
               Transcript.unanswered_calls(entries)
    end

    test "a call id reused in a later wave is matched to its own wave" do
      entries = [
        calling("t1"),
        answering("t1"),
        Entry.new(:request, %{"id" => "r2"}),
        calling("t1")
      ]

      assert [%{id: "t1"}] = Transcript.unanswered_calls(entries)
    end

    test "an error entry ends a wave without answering it" do
      entries = [calling("t1"), Entry.new(:error, %{"reason" => "provider crashed"})]

      assert [%{id: "t1"}] = Transcript.unanswered_calls(entries)
    end
  end

  describe "replay_request/2" do
    test "returns a verified provider-neutral historical request" do
      payload =
        Request.new("test:model", system: "historical", output_schema: [ok: [type: :boolean]])
        |> RequestSnapshot.build(id: "request-1")

      entries = [Entry.new(:request, payload)]

      assert {:ok, replay} = Transcript.replay_request(entries, "request-1")
      assert replay["model"] == "test:model"
      assert replay["system"] == "historical"
      assert replay["output_schema"] == [["ok", [["type", "boolean"]]]]
    end
  end

  describe "latest_assistant_text/1" do
    test "returns every text block from the latest textual assistant entry" do
      entries = [
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "older"}]}),
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "thinking", "thinking" => "private"},
            %{"type" => "text", "text" => "first paragraph"},
            %{"type" => "text", "text" => "second paragraph"}
          ]
        })
      ]

      assert {:ok, "first paragraph\nsecond paragraph"} =
               Transcript.latest_assistant_text(entries)
    end

    test "skips tool-only assistant entries and reports an empty transcript", context do
      tool_call =
        Entry.new(:assistant, %{
          "content" => [],
          "tool_calls" => [%{"id" => "read-1", "name" => "read", "arguments" => %{}}]
        })

      assert {:ok, "second"} = Transcript.latest_assistant_text(context.entries ++ [tool_call])
      assert {:error, :not_found} = Transcript.latest_assistant_text([tool_call])
      assert {:error, :not_found} = Transcript.latest_assistant_text([])
    end
  end
end
