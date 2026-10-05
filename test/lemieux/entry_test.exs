defmodule Lemieux.EntryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry

  describe "new/3" do
    test "stamps an id, the schema version and a UTC timestamp" do
      entry = Entry.new(:user, %{"text" => "hi"})

      assert byte_size(entry.id) == 26
      assert entry.v == 2
      assert entry.at.time_zone == "Etc/UTC"
      assert entry.parent_id == nil
      assert entry.usage == nil
    end

    test "links the child to its parent id" do
      parent = Entry.new(:user, %{"text" => "hi"})
      child = Entry.new(:assistant, %{"content" => []}, parent: parent)

      assert child.parent_id == parent.id
    end

    test "accepts a parent id directly, so a resumed session can link to a stored entry" do
      child = Entry.new(:assistant, %{"content" => []}, parent: "01J000000000000000000000")

      assert child.parent_id == "01J000000000000000000000"
    end

    test "rejects an unknown entry type" do
      # Routed through a value the type checker cannot narrow on purpose: a
      # literal would be caught at compile time, and the check exists for the
      # types that only show up at runtime.
      type = Enum.random([:nonsense])

      assert_raise ArgumentError, ~r/unknown entry type :nonsense/, fn ->
        Entry.new(type, %{})
      end
    end

    test "rejects a payload with atom keys, which would not survive a round trip" do
      # Caught at construction rather than at decode time: an entry that
      # encodes to something that does not decode back is a corrupt log line,
      # and the log is the only copy.
      assert_raise ArgumentError, ~r/payload keys must be strings/, fn ->
        Entry.new(:user, %{text: "hi"})
      end

      assert_raise ArgumentError, ~r/payload keys must be strings/, fn ->
        Entry.new(:user, %{"content" => [%{type: "text"}]})
      end
    end
  end

  describe "encode!/1 and decode!/1" do
    test "encodes to JSON and decodes back to an identical entry" do
      entry =
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "hello"}]},
          parent: "01J000000000000000000000",
          usage: %{"input_tokens" => 12, "output_tokens" => 3}
        )

      assert Entry.decode!(Entry.encode!(entry)) == entry
    end

    test "round-trips an entry with no usage and no parent" do
      entry = Entry.new(:user, %{"text" => "hi"})

      assert Entry.decode!(Entry.encode!(entry)) == entry
    end

    test "encodes to a single line, so a transcript can be JSONL" do
      line = Entry.encode!(Entry.new(:user, %{"text" => "two\nlines"}))

      refute line =~ "\n"
    end

    test "decoding a line written by an unknown schema version is an error, not a guess" do
      line =
        Entry.new(:user, %{"text" => "hi"})
        |> Entry.encode!()
        |> String.replace(~s("v":2), ~s("v":99))

      assert_raise ArgumentError, ~r/schema version 99/, fn -> Entry.decode!(line) end
    end

    test "version one remains readable but cannot contain version two entry types" do
      line =
        Entry.new(:user, %{"text" => "hi"})
        |> Entry.encode!()
        |> String.replace(~s("v":2), ~s("v":1))

      assert %Entry{v: 1, type: :user} = Entry.decode!(line)

      incompatible =
        Entry.new(:harness_snapshot, %{})
        |> Entry.encode!()
        |> String.replace(~s("v":2), ~s("v":1))

      assert_raise ArgumentError, ~r/unknown entry type "harness_snapshot"/, fn ->
        Entry.decode!(incompatible)
      end
    end

    test "decoding a line with an unknown type is an error, not an atom leak" do
      line =
        Entry.new(:user, %{"text" => "hi"})
        |> Entry.encode!()
        |> String.replace(~s("type":"user"), ~s("type":"wat"))

      assert_raise ArgumentError, ~r/unknown entry type "wat"/, fn -> Entry.decode!(line) end
    end
  end

  describe "seq" do
    test "defaults to zero for an entry nobody has placed in a transcript" do
      assert Entry.new(:user, %{"text" => "hi"}).seq == 0
    end

    test "survives the round trip" do
      entry = Entry.new(:user, %{"text" => "hi"}, seq: 7)

      assert Entry.decode!(Entry.encode!(entry)).seq == 7
    end
  end

  describe "meta" do
    test "defaults to empty, so a host that sets nothing carries nothing" do
      assert Entry.new(:user, %{"text" => "hi"}).meta == %{}
    end

    # The extension point for embedders: lemieux owns `payload` and defines it
    # per type, so a host with its own identifiers needs somewhere else to put
    # them.
    test "carries a host's own data through the round trip" do
      entry = Entry.new(:user, %{"text" => "hi"}, meta: %{"host_run_id" => "abc"})

      assert Entry.decode!(Entry.encode!(entry)).meta == %{"host_run_id" => "abc"}
    end

    test "is held to the same JSON shape as a payload" do
      assert_raise ArgumentError, ~r/meta keys must be strings/, fn ->
        Entry.new(:user, %{"text" => "hi"}, meta: %{atom_key: 1})
      end
    end
  end

  describe "the session type" do
    test "records what a session was configured with" do
      config = %{
        "model" => "test:model",
        "system" => "be terse",
        "tools" => ["Elixir.Lemieux.Tools.Read"],
        "cwd" => "/tmp"
      }

      entry = Entry.new(:session, config)

      assert Entry.decode!(Entry.encode!(entry)).payload == config
    end
  end
end
