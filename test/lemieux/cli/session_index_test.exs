defmodule Lemieux.CLI.SessionIndexTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.SessionIndex
  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "returns recent sessions newest first with useful picker labels", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)
    at = ~U[2026-08-15 23:58:00Z]

    for {id, model, prompt} <- [
          {"01OLD", "anthropic:old", "older work"},
          {"02NEW", "openai:new", "  explain\nthis   failure  "}
        ] do
      assert :ok =
               Store.append(store, id, [
                 Entry.new(:session, %{"model" => model}, at: at),
                 Entry.new(:user, %{"text" => prompt}, at: at)
               ])
    end

    assert {:ok, [new, old]} = SessionIndex.recent(store)
    assert new.id == "02NEW"
    assert old.id == "01OLD"

    # Led by the name rather than the id: the label's job is to hand somebody
    # something they can type back, and nobody retypes a ULID.
    assert SessionIndex.label(new) ==
             "#{Shorthand.of("02NEW")} · 2026-08-15 23:58 · openai:new · " <>
               "\u201cexplain this failure\u201d"

    assert new.shorthand == Shorthand.of("02NEW")
  end

  # A delegation of three put three transcripts in front of the newest fifty,
  # and nobody resumes a conversation they never had. The signal is the
  # envelope the coordinator writes into the child's own transcript.
  test "a delegated child's transcript is not offered", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    :ok = Store.append(store, "01PARENT", [Entry.new(:user, %{"text" => "look into it"})])

    :ok =
      Store.append(store, "02CHILD", [
        Entry.new(:user, %{"text" => "Objective:\ninvestigate the build"}),
        Entry.new(:subagent_result, %{"child_id" => "02CHILD", "status" => "ok"})
      ])

    assert {:ok, [parent]} = SessionIndex.recent(store)
    assert parent.id == "01PARENT"
  end

  # The parent's own transcript carries the same entry type, naming its
  # children rather than itself. Reading the type alone would hide every
  # session that ever delegated — which is most of the ones worth resuming.
  test "a parent that delegated is still offered", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    :ok =
      Store.append(store, "01PARENT", [
        Entry.new(:user, %{"text" => "look into it"}),
        Entry.new(:subagent_result, %{"child_id" => "02CHILD", "status" => "ok"})
      ])

    assert {:ok, [parent]} = SessionIndex.recent(store)
    assert parent.id == "01PARENT"
  end

  test "a struct built without a name still has one" do
    assert SessionIndex.shorthand(%SessionIndex{id: "01OLD"}) == Shorthand.of("01OLD")
  end

  # One transcript from a different build of lemieux must not be able to empty
  # the picker. It is a real session and the person may be looking for it, so
  # it is listed with the reason in place of a preview.
  test "a transcript this build cannot read is listed, not fatal", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    :ok = Store.append(store, "01FINE", [Entry.new(:user, %{"text" => "readable"})])
    File.write!(Path.join(tmp_dir, "02FUTURE.jsonl"), ~s({"v":99,"id":"x"}\n))

    assert {:ok, [future, fine]} = SessionIndex.recent(store)

    assert fine.id == "01FINE"
    assert future.id == "02FUTURE"
    assert future.preview =~ "another version"
    assert SessionIndex.label(future) =~ Shorthand.of("02FUTURE")
  end

  test "limits reads to the newest requested sessions", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    for id <- ~w(01FIRST 02SECOND 03THIRD) do
      assert :ok = Store.append(store, id, [Entry.new(:user, %{"text" => id})])
    end

    assert {:ok, sessions} = SessionIndex.recent(store, limit: 2)
    assert Enum.map(sessions, & &1.id) == ~w(03THIRD 02SECOND)
  end

  test "sessions carry where they ran and when they were last active", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)

    for {id, cwd} <- [{"01HERE", "/work/here"}, {"02THERE", "/work/there"}] do
      :ok =
        Store.append(store, id, [
          Entry.new(:session, %{"model" => "test:model", "cwd" => cwd}),
          Entry.new(:user, %{"text" => "work in #{cwd}"})
        ])
    end

    assert {:ok, [there, here]} = SessionIndex.recent(store)
    assert here.cwd == "/work/here"
    assert %DateTime{} = here.updated_at
    assert {:ok, [%SessionIndex{id: "01HERE"}]} = SessionIndex.recent(store, cwd: "/work/here")
    assert SessionIndex.latest(store, "/work/there") == there.id
    assert SessionIndex.latest(store, "/nowhere") == nil
    assert [%SessionIndex{id: "01HERE"}] = SessionIndex.recent(dir: tmp_dir, cwd: "/work/here")
  end

  # Most recently written first, not most recently created: the conversation
  # somebody had this morning, not the one they happened to start first.
  test "the order is last activity, and unchanged transcripts are not read again",
       %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)
    :ok = Store.append(store, "01OLDER", [Entry.new(:user, %{"text" => "first"})])
    :ok = Store.append(store, "02NEWER", [Entry.new(:user, %{"text" => "second"})])
    File.touch!(Path.join(tmp_dir, "01OLDER.jsonl"), System.os_time(:second) + 60)

    assert {:ok, [%{id: "01OLDER"}, %{id: "02NEWER"}]} = SessionIndex.recent(store)
    assert File.exists?(Path.join(tmp_dir, "index.json"))

    # An indexed transcript whose size and time are unchanged is served from
    # the index: corrupting its contents in place does not change the answer.
    path = Path.join(tmp_dir, "02NEWER.jsonl")
    stat = File.stat!(path, time: :posix)
    File.write!(path, String.duplicate("x", stat.size))
    File.touch!(path, stat.mtime)

    assert {:ok, [_older, %{id: "02NEWER", preview: "second"}]} = SessionIndex.recent(store)
  end

  test "an initialized but unused session does not displace real history", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)
    :ok = Store.append(store, "01USED", [Entry.new(:user, %{"text" => "fix the test"})])
    :ok = Store.append(store, "02BLANK", [Entry.new(:session, %{"model" => "test:model"})])

    assert {:ok, [%SessionIndex{id: "01USED"}]} = SessionIndex.recent(store, limit: 1)
    assert {:ok, [%SessionIndex{id: "01USED"}]} = SessionIndex.recent(store)
    assert {:ok, [_entry]} = Store.read(store, "02BLANK")
  end
end
