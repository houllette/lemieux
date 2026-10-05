defmodule Lemieux.Reflection.HostEvidenceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Reflection.HostEvidence

  setup do
    %{entries: entries()}
  end

  # Three requests, two of them answered with usage the session could measure.
  defp entries do
    [
      Entry.new(:user, %{"text" => "go"}, seq: 0, at: at(0)),
      Entry.new(:request, %{"id" => "req_1", "kind" => "turn"}, seq: 1, at: at(1)),
      Entry.new(:assistant, %{"content" => [], "request_id" => "req_1"},
        seq: 2,
        at: at(2),
        usage: %{"input_tokens" => 100, "output_tokens" => 20, "cost_usd" => 0.001}
      ),
      Entry.new(:tool_result, %{"name" => "read", "error" => false}, seq: 3, at: at(3)),
      Entry.new(:request, %{"id" => "req_2", "kind" => "turn"}, seq: 4, at: at(4)),
      Entry.new(:assistant, %{"content" => [], "request_id" => "req_2"},
        seq: 5,
        at: at(5),
        usage: %{"input_tokens" => 200, "output_tokens" => 30, "cost_usd" => 0.002}
      ),
      Entry.new(:request, %{"id" => "req_3", "kind" => "turn"}, seq: 6, at: at(6))
    ]
  end

  defp at(offset), do: DateTime.add(~U[2026-09-17 10:00:00Z], offset, :second)

  # No `tool_calls`: a gateway that does not report a counter has not reported
  # zero for it, and several tests below depend on that distinction.
  defp record(id, opts) do
    %{
      "request_id" => id,
      "observed_at" => DateTime.to_iso8601(at(Keyword.get(opts, :offset, 0))),
      "input_tokens" => Keyword.get(opts, :input, 100),
      "output_tokens" => Keyword.get(opts, :output, 20),
      "cost_usd" => Keyword.get(opts, :cost, 0.001),
      "status" => "ok"
    }
  end

  test "an absent gateway is stated, not implied by an empty section", ctx do
    for absent <- [nil, %{}, %{"availability" => "not supplied"}] do
      projection = HostEvidence.project(absent, ctx.entries)

      assert projection["availability"] == "not supplied"
      assert projection["note"] =~ "complete on its own terms"
      refute Map.has_key?(projection, "reconciliation")
    end
  end

  test "evidence that is not an object is unusable, which is not the same as absent", ctx do
    projection = HostEvidence.project("gateway said fine", ctx.entries)

    assert projection["availability"] == "unusable"
    assert projection["received_type"] == "string"
  end

  test "records correlate to request entries, and every kind of gap is named", ctx do
    evidence = %{
      "source" => "ixway",
      "instance" => "https://gateway.example",
      "collected_at" => DateTime.to_iso8601(at(10)),
      "records" => [
        record("req_1", []),
        record("req_2", input: 200, output: 30, cost: 0.002),
        # A retry the gateway saw and the transcript recorded once.
        record("req_2", input: 5, output: 1, cost: 0.0001),
        # A request from another session on the same gateway key.
        record("req_99", []),
        # A record the gateway could not attribute at all.
        Map.delete(record("req_1", []), "request_id")
      ]
    }

    correlation = HostEvidence.project(evidence, ctx.entries)["correlation"]

    assert correlation["local_requests"] == 3
    assert correlation["gateway_records"] == 5
    assert correlation["matched_requests"] == 2
    assert correlation["gateway_records_without_request"] == ["req_99"]
    assert correlation["duplicate_gateway_records"] == ["req_2"]
    assert correlation["unidentified_gateway_records"] == 1

    # req_3 was recorded locally and never seen by the gateway; it is named by
    # entry id so a reader can go and look at it.
    assert [missing] = correlation["requests_without_gateway_record"]
    assert missing == Enum.at(ctx.entries, 6).id

    assert [turn_1, _turn_2, turn_3] = correlation["turns"]
    assert turn_1["request_id"] == "req_1" and turn_1["matched"]
    assert turn_3["request_id"] == "req_3" and turn_3["matched"] == false
  end

  test "local and gateway totals are compared, never summed", ctx do
    evidence = %{
      "source" => "ixway",
      "collected_at" => DateTime.to_iso8601(at(10)),
      "records" => [
        record("req_1", []),
        record("req_2", input: 200, output: 30, cost: 0.002)
      ]
    }

    reconciliation = HostEvidence.project(evidence, ctx.entries)["reconciliation"]

    # The session measured 300 input tokens across two usage reports, and so
    # did the gateway. The projection says they agree; it does not say 600.
    assert reconciliation["local"]["input_tokens"] == 300
    assert reconciliation["gateway"]["input_tokens"] == 300
    assert reconciliation["comparison"]["input_tokens"]["state"] == "agrees"
    assert reconciliation["comparison"]["input_tokens"]["difference"] == 0
    assert reconciliation["gateway_totals_source"] == "summed_from_records"

    # Tool calls the gateway never reported stay unknown rather than zero,
    # even though the session counted one.
    assert reconciliation["local"]["tool_calls"] == 1
    assert reconciliation["comparison"]["tool_calls"]["state"] == "unknown"
  end

  test "a declared gateway total wins over a sum of its own records", ctx do
    evidence = %{
      "source" => "ixway",
      "collected_at" => DateTime.to_iso8601(at(10)),
      "records" => [record("req_1", [])],
      "totals" => %{"input_tokens" => 420, "output_tokens" => 50}
    }

    reconciliation = HostEvidence.project(evidence, ctx.entries)["reconciliation"]

    assert reconciliation["gateway_totals_source"] == "declared"
    assert reconciliation["gateway"]["input_tokens"] == 420
    assert reconciliation["comparison"]["input_tokens"]["state"] == "differs"
    assert reconciliation["comparison"]["input_tokens"]["difference"] == 120
  end

  test "a window that closes before the session did excuses the records it is missing", ctx do
    behind =
      HostEvidence.project(
        %{
          "source" => "ixway",
          "window" => %{
            "from" => DateTime.to_iso8601(at(0)),
            "to" => DateTime.to_iso8601(at(3))
          },
          "records" => [record("req_1", [])]
        },
        ctx.entries
      )

    assert behind["freshness"]["state"] == "behind_session"
    assert behind["freshness"]["covers_session"] == false
    assert behind["freshness"]["lag_ms"] == 3_000

    current =
      HostEvidence.project(
        %{
          "source" => "ixway",
          "collected_at" => DateTime.to_iso8601(at(60)),
          "records" => [record("req_1", [])]
        },
        ctx.entries
      )

    assert current["freshness"]["state"] == "covers_session"
    assert current["freshness"]["covers_session"] == true
    assert current["freshness"]["lag_ms"] == -54_000
  end

  test "freshness is unknown rather than guessed when nothing dates the evidence", ctx do
    projection =
      HostEvidence.project(
        %{"source" => "ixway", "records" => [record("req_1", [])]},
        ctx.entries
      )

    assert projection["freshness"]["state"] == "unknown"
    assert projection["freshness"]["covers_session"] == nil
    assert projection["freshness"]["lag_ms"] == nil
    assert "undated" in kinds(projection)
  end

  test "problems name each thing a reader would otherwise have to notice", ctx do
    projection =
      HostEvidence.project(
        %{
          "records" => [
            record("req_1", []),
            record("req_1", []),
            Map.delete(record("req_2", []), "request_id")
          ]
        },
        ctx.entries
      )

    kinds = kinds(projection)
    assert "unattributed" in kinds
    assert "undated" in kinds
    assert "duplicate_gateway_records" in kinds
    assert "unidentified_gateway_records" in kinds
    assert "requests_without_gateway_record" in kinds
    assert projection["provenance"]["attributed"] == false
    assert projection["provenance"]["source"] == "unattributed"

    empty = HostEvidence.project(%{"source" => "ixway", "records" => []}, ctx.entries)
    assert "no_records" in kinds(empty)
  end

  test "a session with no requests still projects rather than dividing by nothing" do
    projection = HostEvidence.project(%{"source" => "ixway", "records" => []}, [])

    assert projection["availability"] == "supplied"
    assert projection["correlation"]["local_requests"] == 0
    assert projection["reconciliation"]["local"]["input_tokens"] == nil
    assert projection["freshness"]["latest_local_entry_at"] == nil
  end

  test "long lists are truncated with their true count kept", ctx do
    many = for index <- 1..40, do: record("ghost_#{index}", [])
    projection = HostEvidence.project(%{"source" => "ixway", "records" => many}, ctx.entries)

    assert %{"count" => 40, "listed" => listed, "truncated" => 15} =
             projection["correlation"]["gateway_records_without_request"]

    assert length(listed) == 25
  end

  # The roadmap's standing constraint: this seam takes host-supplied data and
  # never reaches for a gateway itself. A call into `Lemieux.Ixway` (inference
  # routing) or an HTTP client here would make the core depend on a gateway to
  # reflect at all, which is the thing the seam exists to avoid.
  test "the projection calls no gateway client" do
    # The beam on disk, not `:code.which/1`: under `mix test --cover` that
    # answers `:cover_compiled`, and the nightly coverage job failed here.
    path = :lemieux |> Application.app_dir("ebin/#{HostEvidence}.beam") |> String.to_charlist()
    {:ok, {HostEvidence, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert Lemieux.Ixway not in called
    assert Req not in called
    assert Finch not in called
    assert Enum.all?(called, &(not (&1 |> to_string() |> String.contains?("Ixway"))))
  end

  defp kinds(projection), do: Enum.map(projection["problems"], & &1["kind"])
end
