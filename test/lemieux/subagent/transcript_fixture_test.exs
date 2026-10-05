defmodule Lemieux.Subagent.TranscriptFixtureTest do
  @moduledoc """
  A delegated tree this build did not write, replayed by this build.

  Every other subagent test writes a transcript and reads it back in the same
  process, which proves the two halves agree with each other and nothing about
  whether either agrees with what is already on disk. A host that resumes a
  session started last month is reading exactly that: bytes a different build
  produced. So these fixtures are committed, versioned by the transcript
  schema they were written under, and read here without being regenerated.

  When a change to the durable shape breaks this, that is the point: the file
  says what an existing transcript looks like, and the choice is to keep
  reading it or to say in `docs/transcript-compatibility.md` why not.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent.Replay
  alias Lemieux.Subagent.Result

  @fixtures Path.expand("../../fixtures/subagent/v2", __DIR__)

  setup do
    %{store: JSONL.new(@fixtures), expected: @fixtures |> Path.join("expected.json") |> read()}
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()

  test "a committed parent transcript replays into its group and children", ctx do
    assert {:ok, tree} = Replay.tree(ctx.store, ctx.expected["parent_session_id"])

    assert [group] = tree.groups
    assert group.id == ctx.expected["group_id"]
    assert group.status == :ok

    assert Enum.map(group.children, & &1.id) ==
             Enum.map(ctx.expected["children"], & &1["child_id"])

    Enum.zip(group.children, ctx.expected["children"])
    |> Enum.each(fn {replayed, expected} ->
      assert replayed.definition_id == expected["definition_id"]
      assert Atom.to_string(replayed.status) == expected["status"]
      assert replayed.result.answer == expected["answer"]
      assert Atom.to_string(replayed.result.format) == expected["format"]
      assert is_binary(replayed.definition_digest)
    end)
  end

  test "the spawn intents carry the composed deadline that bound each child", ctx do
    {:ok, entries} = Store.read(ctx.store, ctx.expected["parent_session_id"])
    spawns = Enum.filter(entries, &(&1.type == :subagent_spawn))

    assert length(spawns) == length(ctx.expected["children"])

    Enum.each(spawns, fn spawn ->
      effective = spawn.payload["effective_deadline_ms"]

      assert is_integer(effective)
      assert effective <= spawn.payload["child_timeout_ms"]
      assert effective <= spawn.payload["group_timeout_ms"]
      assert spawn.payload["deadline_source"] in ["group", "host", "runtime_maximum"]
      assert spawn.payload["depth"] == 1
      assert spawn.payload["authority"]["read_only"] == true
    end)
  end

  test "a child transcript was never given authority the definition withheld", ctx do
    Enum.each(ctx.expected["children"], fn child ->
      {:ok, entries} = Store.read(ctx.store, child["child_id"])
      session = Enum.find(entries, &(&1.type == :session))

      assert session.payload["tools"] == [to_string(Lemieux.Tools.Read)]
      refute Enum.any?(entries, &(&1.type == :subagent_spawn))
    end)
  end

  test "an envelope written before `format` existed still reads", ctx do
    # The one compatibility question this change actually raises: older
    # transcripts have no `format` key. Stripping it here is the same as
    # reading a transcript a previous build wrote.
    {:ok, entries} = Store.read(ctx.store, ctx.expected["parent_session_id"])

    entries
    |> Enum.filter(&(&1.type == :subagent_result))
    |> Enum.each(fn entry ->
      legacy = Map.delete(entry.payload, "format")

      assert {:ok, result} = Result.from_map(legacy)
      assert result.format == :structured
      assert result.answer != ""
    end)
  end
end
