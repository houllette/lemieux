defmodule Lemieux.Reflection.OpportunitiesTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Feedback, as: FeedbackCLI
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
  alias Lemieux.Providers.Scripted
  alias Lemieux.Reflection.Opportunities

  @moduletag :tmp_dir

  test "parse is lenient about surrounding prose and strict about shape" do
    answer = """
    Here is what I found:
    [
      {"title": "Never reran the check", "claim": "The agent edited value.txt and finished without rerunning check.sh.",
       "type": "bug", "verifiability": "mechanical", "evidence_entry_ids": ["e7", "e9"],
       "proposed_case": {"prompt": "Fix value.txt and rerun the check.", "verifier": ["sh", "check.sh"], "allowed_changed_paths": ["value.txt"]},
       "confidence": 0.8},
      {"title": "Vague", "claim": "Something felt off.", "type": "vibes", "verifiability": "guess", "confidence": 7},
      {"nonsense": true}
    ]
    """

    assert [first, second] = Opportunities.parse(answer)
    assert first["type"] == "bug" and first["verifiability"] == "mechanical"
    assert first["proposed_case"]["verifier"] == ["sh", "check.sh"]
    assert first["confidence"] == 0.8
    assert second["type"] == "unknown" and second["verifiability"] == "unknown"
    assert second["proposed_case"] == nil and second["confidence"] == nil

    assert Opportunities.parse("No JSON here.") == []
    assert Opportunities.parse(nil) == []
    assert Opportunities.parse("[]") == []
  end

  test "mine runs one tool-less session over the evidence and returns opportunities", %{
    tmp_dir: tmp_dir
  } do
    entries = transcript()
    owner = self()

    provider =
      Scripted.new([
        fn request ->
          send(owner, {:request, request})

          Scripted.complete(
            ~s([{"title": "T", "claim": "C", "type": "bug", "verifiability": "mechanical", "evidence_entry_ids": ["e2"], "proposed_case": null, "confidence": 0.5}])
          )
        end
      ])

    assert {:ok, [opportunity], observation} =
             Opportunities.mine(entries,
               provider: provider,
               model: "test:model",
               sessions_dir: Path.join(tmp_dir, "s"),
               cwd: tmp_dir
             )

    assert opportunity["title"] == "T"
    assert observation["status"] == "completed"
    assert_received {:request, request}
    assert request.tools == []
    assert request.system =~ "OUTPUT CONTRACT"
    assert request.system =~ "UNTRUSTED historical evidence"
    assert request.system =~ "e2"
  end

  test "mine gives the reflection a generous output budget so a reasoning model can finish", %{
    tmp_dir: tmp_dir
  } do
    # Found live: `zai_coding_plan:glm-5.3` spent all 4096 of the previous
    # default on reasoning tokens and returned an empty answer, so mining
    # silently found nothing on ten real sessions. The budget has to leave room
    # for the JSON array after the thinking. An explicit `:max_tokens` still
    # wins, so a caller can go higher or lower.
    owner = self()

    provider =
      Scripted.new([
        fn request ->
          send(owner, {:params, request.params})
          Scripted.complete("[]")
        end,
        fn request ->
          send(owner, {:params, request.params})
          Scripted.complete("[]")
        end
      ])

    assert {:ok, [], _} =
             Opportunities.mine(transcript(),
               provider: provider,
               model: "test:model",
               sessions_dir: Path.join(tmp_dir, "default"),
               cwd: tmp_dir
             )

    assert_received {:params, params}
    assert Keyword.fetch!(params, :max_tokens) >= 16_000

    assert {:ok, [], _} =
             Opportunities.mine(transcript(),
               provider: provider,
               model: "test:model",
               sessions_dir: Path.join(tmp_dir, "explicit"),
               cwd: tmp_dir,
               max_tokens: 2048
             )

    assert_received {:params, params}
    assert Keyword.fetch!(params, :max_tokens) == 2048
  end

  test "mine refuses invented citations instead of turning them into feedback", %{tmp_dir: dir} do
    provider = Scripted.new([Scripted.complete(opportunity_answer(["e2", "invented"]))])

    assert {:error, {:invalid_evidence_entry_ids, ["invented"]}} =
             Opportunities.mine(transcript(),
               provider: provider,
               model: "test:model",
               sessions_dir: Path.join(dir, "sessions"),
               cwd: dir
             )
  end

  test "mining cannot cite a real entry omitted from its bounded evidence", %{tmp_dir: dir} do
    entries = transcript()
    evidence = Lemieux.Reflection.gather(entries, max_evidence_bytes: 512)
    shown = MapSet.new(evidence["events"], & &1["id"])
    omitted = Enum.find(entries, &(not MapSet.member?(shown, &1.id)))
    assert omitted != nil
    id = omitted.id
    provider = Scripted.new([Scripted.complete(opportunity_answer([id]))])

    assert {:error, {:invalid_evidence_entry_ids, [^id]}} =
             Opportunities.mine(entries,
               provider: provider,
               model: "test:model",
               sessions_dir: Path.join(dir, "sessions"),
               cwd: dir,
               max_evidence_bytes: 512
             )
  end

  test "record validates every citation in the batch before writing feedback", %{tmp_dir: dir} do
    store = FeedbackJSONL.new(Path.join(dir, "feedback"))
    [valid] = Opportunities.parse(opportunity_answer(["e2"]))
    [invalid] = Opportunities.parse(opportunity_answer(["e2", "invented"]))
    provenance = %{"tenant_id" => "local", "project_id" => "proj", "session_id" => "sess"}

    assert {:error, {:invalid_evidence_entry_ids, ["invented"]}} =
             Opportunities.record([valid, invalid], provenance, store,
               source_entries: transcript(),
               fallback_entry_id: "e3"
             )

    assert {:ok, []} = FeedbackStore.list_feedback(store)
  end

  test "record requires host source entries and refuses an unknown fallback", %{tmp_dir: dir} do
    store = FeedbackJSONL.new(Path.join(dir, "feedback"))
    opportunities = Opportunities.parse(opportunity_answer([]))
    provenance = %{"tenant_id" => "local", "project_id" => "proj", "session_id" => "sess"}

    assert {:error, :source_entries_required} =
             Opportunities.record(opportunities, provenance, store, fallback_entry_id: "e3")

    assert {:error, {:invalid_evidence_entry_ids, ["invented"]}} =
             Opportunities.record(opportunities, provenance, store,
               source_entries: transcript(),
               fallback_entry_id: "invented"
             )

    assert {:ok, []} = FeedbackStore.list_feedback(store)
  end

  test "interactive reflection harvesting refuses invented anchors", %{tmp_dir: dir} do
    answer =
      Entry.new(
        :assistant,
        %{"content" => [%{"type" => "text", "text" => opportunity_answer(["invented"])}]},
        id: "reflection-answer",
        seq: 4
      )

    store = FeedbackJSONL.new(Path.join(dir, "feedback"))

    assert {:error, {:invalid_evidence_entry_ids, ["invented"]}} =
             FeedbackCLI.harvest(
               %{entries: transcript() ++ [answer], id: "sess", model: "test:model"},
               feedback_store: store
             )

    assert {:ok, []} = FeedbackStore.list_feedback(store)
  end

  test "record refuses empty or ambiguous host source entries", %{tmp_dir: dir} do
    store = FeedbackJSONL.new(Path.join(dir, "feedback"))
    opportunities = Opportunities.parse(opportunity_answer(["e2"]))
    provenance = %{"tenant_id" => "local", "project_id" => "proj", "session_id" => "sess"}
    entries = transcript()

    for source <- [[], [List.first(entries) | entries]] do
      assert {:error, :invalid_source_entries} =
               Opportunities.record(opportunities, provenance, store, source_entries: source)
    end

    assert {:ok, []} = FeedbackStore.list_feedback(store)
  end

  test "the CLI refuses invalid mining before creating feedback and preserves the source", %{
    tmp_dir: dir
  } do
    sessions = Path.join(dir, "sessions")
    store = Lemieux.Store.JSONL.new(sessions)
    session_id = "01MINE00000000000000000002"
    :ok = Lemieux.Store.append(store, session_id, transcript())
    before = File.read!(Path.join(sessions, session_id <> ".jsonl"))
    provider = Scripted.new([Scripted.complete(opportunity_answer(["invented"]))])
    feedback = Path.join(dir, "feedback")

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        stdout =
          ExUnit.CaptureIO.capture_io(fn ->
            assert {:error, 1} =
                     FeedbackCLI.run(
                       [
                         "--mine",
                         session_id,
                         "--sessions-dir",
                         sessions,
                         "--feedback-dir",
                         feedback
                       ],
                       provider: provider,
                       model: "test:model"
                     )
          end)

        assert stdout == ""
      end)

    assert stderr =~ "outside its source evidence"
    refute File.exists?(feedback)
    assert File.read!(Path.join(sessions, session_id <> ".jsonl")) == before
  end

  # Found live: a GLM reflection answered with well-formed objects that had no
  # `title`, and every one of them was discarded. The label is how a person
  # recognises a record, not part of the finding.
  test "a claim with no label keeps its finding and takes a label from the claim" do
    claim = "The read tool gives no hint when a file is missing. A listing would help."

    assert [opportunity] =
             Opportunities.parse(
               ~s([{"claim": "#{claim}", "type": "bug", "verifiability": "mechanical",
                    "evidence_entry_ids": [], "confidence": 0.4}])
             )

    assert opportunity["title"] == "The read tool gives no hint when a file is missing."
    assert opportunity["claim"] == claim
    assert opportunity["type"] == "bug"

    # A label the model did supply is never rewritten.
    assert [kept] =
             Opportunities.parse(
               ~s([{"title": "Mine", "claim": "C", "type": "bug", "verifiability": "unknown",
                    "evidence_entry_ids": [], "confidence": 0.4}])
             )

    assert kept["title"] == "Mine"

    # An element with neither is still nothing.
    assert Opportunities.parse(~s([{"type": "bug"}])) == []
  end

  test "record writes feedback with a model actor and reflection provenance", %{tmp_dir: tmp_dir} do
    store = FeedbackJSONL.new(Path.join(tmp_dir, "feedback"))
    entries = transcript()

    opportunities =
      Opportunities.parse(
        ~s([{"title": "T", "claim": "C", "type": "bug", "verifiability": "mechanical", "evidence_entry_ids": ["e2"], "proposed_case": null, "confidence": 0.5},
                              {"title": "U", "claim": "D", "type": "unknown", "verifiability": "unknown", "evidence_entry_ids": [], "proposed_case": null, "confidence": null}])
      )

    provenance = %{"tenant_id" => "local", "project_id" => "proj", "session_id" => "sess"}

    assert {:ok, [id1, id2]} =
             Opportunities.record(opportunities, provenance, store,
               model: "test:model",
               fallback_entry_id: "e3",
               source_entries: entries
             )

    assert {:ok, first} = FeedbackStore.latest(store, id1)
    assert first.raw_text == "T: C"
    assert first.actor == %{"type" => "model", "id" => "test:model"}
    assert first.provenance["host"] == "reflection"
    assert first.provenance["entry_id"] == "e2"
    validation = first.provenance["evidence_validation"]
    assert validation["policy"] == "transcript_entry_membership/v1"
    assert validation["anchor_kind"] == "citation"
    assert validation["source_entry_count"] == 3

    assert validation["source_entries_sha256"] ==
             Contract.sha256(Enum.map(entries, &[Entry.encode!(&1), ?\n]))

    assert first.type == :bug
    assert first.verifiability["class"] == "mechanical"
    assert first.status == :captured
    assert {:ok, second} = FeedbackStore.latest(store, id2)
    assert second.provenance["entry_id"] == "e3"
    assert second.provenance["evidence_validation"]["anchor_kind"] == "fallback"
    assert second.type == :unknown

    assert {:ok, []} = Opportunities.record([], provenance, store)
  end

  # The bug this pins was found live, not here: `String.to_existing_atom/1`
  # needed `Lemieux.Feedback` to be *loaded* before the atom existed, and a
  # gpt-5.6 reflection that named a `product_requirement` in a fresh VM
  # crashed the whole mining run on its first opportunity. Every type the
  # output contract offers has to reach a record.
  test "every type the output contract offers becomes a record", %{tmp_dir: tmp_dir} do
    store = FeedbackJSONL.new(Path.join(tmp_dir, "feedback"))
    types = ~w(bug missed_requirement product_requirement style_preference taste unknown)

    opportunities =
      types
      |> Enum.map_join(",", fn type ->
        ~s({"title": "#{type}", "claim": "C", "type": "#{type}", "verifiability": "unknown",
            "evidence_entry_ids": [], "proposed_case": null, "confidence": 0.5})
      end)
      |> then(&Opportunities.parse("[" <> &1 <> "]"))

    assert length(opportunities) == length(types)
    provenance = %{"tenant_id" => "local", "project_id" => "proj", "session_id" => "sess"}

    assert {:ok, ids} =
             Opportunities.record(opportunities, provenance, store,
               model: "test:model",
               fallback_entry_id: "e1",
               source_entries: transcript()
             )

    recorded =
      Enum.map(ids, fn id ->
        {:ok, record} = FeedbackStore.latest(store, id)
        Atom.to_string(record.type)
      end)

    assert recorded == types
  end

  test "the CLI mines a stored session into the feedback ledger", %{tmp_dir: tmp_dir} do
    sessions = Path.join(tmp_dir, "sessions")
    store = Lemieux.Store.JSONL.new(sessions)
    session_id = "01MINE00000000000000000000"
    :ok = Lemieux.Store.append(store, session_id, transcript())

    provider =
      Scripted.new([
        Scripted.complete(
          ~s([{"title": "T", "claim": "C", "type": "bug", "verifiability": "mechanical", "evidence_entry_ids": ["e2"], "proposed_case": null, "confidence": 0.5}])
        )
      ])

    feedback_dir = Path.join(tmp_dir, "feedback")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 FeedbackCLI.run(
                   [
                     "--mine",
                     session_id,
                     "--sessions-dir",
                     sessions,
                     "--feedback-dir",
                     feedback_dir
                   ],
                   provider: provider,
                   model: "test:model"
                 )
      end)

    assert output =~ "mined 1 opportunities"
    assert [file] = File.ls!(feedback_dir)
    assert file =~ ~r/^fb_.*\.jsonl$/
  end

  test "the CLI passes --max-tokens and --reasoning-effort to the reflection", %{
    tmp_dir: tmp_dir
  } do
    sessions = Path.join(tmp_dir, "sessions")
    store = Lemieux.Store.JSONL.new(sessions)
    session_id = "01MINE00000000000000000001"
    :ok = Lemieux.Store.append(store, session_id, transcript())
    owner = self()

    provider =
      Scripted.new([
        fn request ->
          send(owner, {:request, request})
          Scripted.complete("[]")
        end
      ])

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok =
               FeedbackCLI.run(
                 [
                   "--mine",
                   session_id,
                   "--sessions-dir",
                   sessions,
                   "--feedback-dir",
                   Path.join(tmp_dir, "feedback"),
                   "--max-tokens",
                   "9000",
                   "--reasoning-effort",
                   "high"
                 ],
                 provider: provider,
                 model: "test:model"
               )
    end)

    assert_received {:request, request}
    assert Keyword.fetch!(request.params, :max_tokens) == 9000
    assert Keyword.get(request.params, :reasoning_effort) == "high"
  end

  defp opportunity_answer(ids) do
    JSON.encode!([
      %{
        "title" => "Unverified work",
        "claim" => "The agent did not verify its edit.",
        "type" => "bug",
        "verifiability" => "mechanical",
        "evidence_entry_ids" => ids
      }
    ])
  end

  defp transcript do
    [
      Entry.new(:user, %{"content" => "Fix value.txt and rerun the check."}, id: "e1", seq: 1),
      Entry.new(
        :tool_result,
        %{
          "call_id" => "c1",
          "name" => "edit",
          "arguments" => %{},
          "output" => "edited",
          "error" => false,
          "outcome" => "success",
          "duration_ms" => 1,
          "output_bytes" => 6
        },
        id: "e2",
        seq: 2
      ),
      Entry.new(
        :assistant,
        %{"content" => [%{"type" => "text", "text" => "Done."}], "tool_calls" => []},
        id: "e3",
        seq: 3
      )
    ]
  end
end
