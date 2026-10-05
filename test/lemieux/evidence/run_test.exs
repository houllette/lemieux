defmodule Lemieux.Evidence.RunTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot

  test "indexes transcript facts without copying prompt or tool content" do
    snapshot = Snapshot.build(Request.new("test:model"))

    request =
      Request.new("test:model")
      |> RequestSnapshot.build(
        harness_snapshot_id: snapshot.id,
        harness_snapshot_sha256: snapshot.semantic_sha256
      )

    entries = [
      Entry.new(:user, %{"text" => "secret prompt"}),
      Entry.new(:request, request),
      Entry.new(
        :tool_result,
        %{
          "call_id" => "call-1",
          "name" => "read",
          "arguments" => %{"path" => "/secret"},
          "output" => "secret body",
          "error" => false,
          "outcome" => "ok",
          "hook_rewritten" => true,
          "duration_ms" => 2,
          "output_bytes" => 11
        }
      ),
      Entry.new(:assistant, %{"content" => [], "request_id" => request["id"]},
        usage: %{"input_tokens" => 2, "output_tokens" => 1, "cost_usd" => nil}
      )
    ]

    assert {:ok, run} =
             Run.from_entries(entries, %{
               id: "run-1",
               model: "test:model",
               stop_reason: :stop,
               correlations: %{session_id: "session", root_session_id: "session", run_id: "run-1"},
               harness_snapshot: snapshot,
               latency_ms: 10
             })

    assert run.outcome == "succeeded"
    assert run.usage["state"] == "complete"
    assert run.cost == %{"state" => "unknown", "usd" => nil, "reason" => "price_missing"}
    assert run.transcript["entry_ids"] == Enum.map(entries, & &1.id)
    assert run.transcript["sequences"] == Enum.map(entries, & &1.seq)

    transcript = Enum.find(run.artifacts, &(&1.id == run.transcript["artifact_id"]))
    transcript_bytes = Enum.map_join(entries, "\n", &Entry.encode!/1)
    assert ArtifactReference.verify_bytes(transcript, transcript_bytes) == :ok

    assert [tool] = run.observations["tool_outcomes"]
    assert tool["hook_rewritten"] == true
    refute Map.has_key?(tool, "arguments")
    refute Map.has_key?(tool, "output")
    refute Run.encode!(run) =~ "secret prompt"
    refute Run.encode!(run) =~ "/secret"
    assert Run.verify(run) == :ok
    assert {:ok, ^run} = run |> Run.encode!() |> Run.decode()
  end

  test "canceled and missing evidence remains an observation with explicit unknowns" do
    snapshot = Snapshot.build(Request.new("test:model"))
    entries = [Entry.new(:cancelled, %{"reason" => "operator"})]

    assert {:ok, run} =
             Run.from_entries(entries, %{
               id: "run-canceled",
               model: "test:model",
               stop_reason: :cancelled,
               correlations: %{
                 session_id: "session",
                 root_session_id: "session",
                 run_id: "run-canceled"
               },
               harness_snapshot: snapshot
             })

    assert run.outcome == "canceled"
    assert run.usage == %{"state" => "unknown", "value" => nil, "reason" => "not_reported"}
    assert run.cost == %{"state" => "unknown", "usd" => nil, "reason" => "not_reported"}
    assert run.completeness["sandbox"] == "unknown"
    refute run.cost["usd"] == 0
  end

  test "timed-out runs preserve partial usage instead of appearing successful" do
    snapshot = Snapshot.build(Request.new("test:model"))

    entries = [
      Entry.new(:assistant, %{"content" => []},
        usage: %{"input_tokens" => 2, "output_tokens" => 1}
      ),
      Entry.new(:compaction, %{"summary" => "omitted"})
    ]

    assert {:ok, run} =
             Run.from_entries(entries, %{
               id: "run-timeout",
               model: "test:model",
               stop_reason: :timeout,
               correlations: %{
                 session_id: "session",
                 root_session_id: "session",
                 run_id: "run-timeout"
               },
               harness_snapshot: snapshot
             })

    assert run.outcome == "timed_out"
    assert run.usage["state"] == "partial"
    assert run.usage["value"] == nil
    assert run.usage["observed"]["input_tokens"] == 2
    assert run.usage["observed"]["output_tokens"] == 1
    assert run.cost == %{"state" => "unknown", "usd" => nil, "reason" => "price_missing"}
  end

  test "every content reference carries digest, media type, and schema version" do
    snapshot = Snapshot.build(Request.new("test:model"))

    assert {:ok, run} =
             Run.from_entries([], %{
               id: "run-empty",
               model: "test:model",
               stop_reason: :error,
               correlations: %{
                 session_id: "session",
                 root_session_id: "session",
                 run_id: "run-empty"
               },
               harness_snapshot: snapshot
             })

    assert Enum.all?(run.artifacts, fn reference ->
             byte_size(reference.sha256) == 64 and reference.media_type != "" and
               reference.content_schema != "" and reference.schema_version == 1
           end)

    assert {:error, :digest_mismatch} =
             run |> Run.to_map() |> Map.put("outcome", "succeeded") |> Run.verify()

    assert {:error, :semantic_digest_mismatch} =
             Run.from_entries([], %{
               id: "run-tampered-harness",
               model: "test:model",
               stop_reason: :error,
               correlations: %{
                 session_id: "session",
                 root_session_id: "session",
                 run_id: "run-tampered-harness"
               },
               harness_snapshot: %{snapshot | model: "tampered:model"}
             })
  end

  test "an unanswered request makes prior measured usage and cost incomplete" do
    snapshot = Snapshot.build(Request.new("test:model"))

    build_request = fn ->
      Request.new("test:model")
      |> RequestSnapshot.build(
        harness_snapshot_id: snapshot.id,
        harness_snapshot_sha256: snapshot.semantic_sha256
      )
    end

    first = build_request.()
    unanswered = build_request.()

    entries = [
      Entry.new(:request, first),
      Entry.new(:assistant, %{"content" => [], "request_id" => first["id"]},
        usage: %{
          "input_tokens" => 2,
          "output_tokens" => 1,
          "cache_read_tokens" => 1,
          "cost_usd" => 0.01
        }
      ),
      Entry.new(:request, unanswered),
      Entry.new(:error, %{"reason" => ":timeout", "request_id" => unanswered["id"]})
    ]

    assert {:ok, run} =
             Run.from_entries(entries, %{
               id: "run-unanswered",
               model: "test:model",
               stop_reason: :error,
               correlations: %{
                 session_id: "session",
                 root_session_id: "session",
                 run_id: "run-unanswered"
               },
               harness_snapshot: snapshot
             })

    assert run.usage["state"] == "partial"
    assert run.usage["value"] == nil
    assert run.usage["observed"]["input_tokens"] == 2
    assert run.usage["observed"]["output_tokens"] == 1
    assert run.usage["observed"]["cache_read_tokens"] == 1
    assert run.cost == %{"state" => "unknown", "usd" => nil, "reason" => "price_missing"}
    assert run.cache == %{"state" => "unknown", "read_tokens" => nil, "write_tokens" => nil}
    assert run.completeness["usage"] == "partial"
  end
end
