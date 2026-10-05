defmodule Lemieux.Subagent.ReplayTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent.Artifact
  alias Lemieux.Subagent.Replay

  @tag :tmp_dir
  test "replay distinguishes missing children from terminal unreconciled transcripts", context do
    store = JSONL.new(context.tmp_dir)

    missing =
      Entry.new(:subagent_spawn, %{
        "child_id" => "missing",
        "group_id" => "group",
        "definition_id" => "scout",
        "definition_digest" => "digest"
      })

    terminal =
      Entry.new(
        :subagent_spawn,
        %{
          "child_id" => "terminal",
          "group_id" => "group",
          "definition_id" => "scout",
          "definition_digest" => "digest"
        },
        parent: missing,
        seq: 1
      )

    :ok = Store.append(store, "parent", [missing, terminal])
    :ok = Store.append(store, "terminal", [Entry.new(:cancelled, %{"reason" => "crash"})])

    assert {:ok, %{groups: [%{status: :incomplete, children: children}]}} =
             Replay.tree(store, "parent")

    assert Enum.map(children, &{&1.id, &1.status}) == [
             {"missing", :incomplete},
             {"terminal", :unreconciled}
           ]
  end

  @tag :tmp_dir
  test "file artifacts are rejected after their recorded content changes", context do
    path = Path.join(context.tmp_dir, "evidence.txt")
    File.write!(path, "first")
    digest = "first" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    artifact = %{"kind" => "file", "ref" => path, "digest" => digest}

    assert :ok = Artifact.verify(artifact)
    File.write!(path, "second")
    assert {:error, {:stale, %{ref: ^path}}} = Artifact.verify(artifact)
  end
end
