defmodule Lemieux.Reflection.HostEvidence do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  What a host's gateway saw, correlated with what this session recorded — and
  never added to it.

  A gateway in front of the provider observes the same requests the transcript
  does, from the other side. That is worth having: it prices requests the
  session could not price, it sees retries the session never learned about,
  and it is the only party that can say a request left the machine at all.
  What it must never become is a second set of numbers quietly summed into the
  first. Two observations of one request are still one request, and a
  reflection that added them would report double the tokens and invent a cost
  that nobody was charged.

  So this module produces a *projection*, not a merge. Local totals stay
  exactly as `Lemieux.Reflection.gather/2` computed them, gateway totals sit
  beside them, and the only derived number is the difference between the two,
  labelled as a disagreement to investigate rather than a correction to apply.

  Four questions decide whether gateway evidence is worth reading at all, and
  each one is answered explicitly rather than left to the model to infer:

    * **Provenance** — which gateway, which instance, which scope, and when it
      was collected. Unattributed numbers are not evidence.
    * **Freshness** — how far behind the session the gateway's own window
      ends. A gateway that stopped collecting before the session finished
      cannot have seen the last requests, and absence of a record then means
      nothing.
    * **Missingness** — which local requests have no gateway record, which
      gateway records match no local request, and which arrived twice. All
      three are ordinary and all three change what a total means.
    * **Correlation** — which gateway record belongs to which request entry,
      by the request id the transcript already records.

  Nothing here talks to Ixway or to any other gateway. It is a pure function
  over a map the host supplies and the entries the session already has, which
  is what keeps the core free of a gateway client: `Lemieux.Ixway` routes
  inference and is a different concern entirely. A host that has no gateway
  supplies nothing and reflection stays exactly as useful as it was.

  ## The shape a host supplies

      %{
        "source" => "ixway",                        # required
        "instance" => "https://gateway.example",    # optional
        "scope" => %{"tenant_id" => "t1"},          # optional
        "collected_at" => "2026-09-17T10:00:00Z",   # optional
        "window" => %{"from" => iso8601, "to" => iso8601},
        "records" => [
          %{
            "request_id" => "req_1",                # correlates with a request entry
            "observed_at" => iso8601,
            "input_tokens" => 120, "output_tokens" => 48,
            "cost_usd" => 0.0004, "tool_calls" => 1,
            "status" => "ok"
          }
        ],
        "totals" => %{"input_tokens" => 120}        # optional gateway aggregate
      }

  Unknown keys are kept, clipped and redacted like any other quoted evidence.
  Missing counters stay missing: a gateway that reports no dollars has not
  reported zero dollars.
  """

  alias Lemieux.Entry

  @counters ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens cost_usd tool_calls)
  @max_listed 25
  @not_supplied %{
    "availability" => "not supplied",
    "note" =>
      "no host gateway evidence was supplied; local transcript accounting is the only " <>
        "observation and is complete on its own terms"
  }

  @typedoc "The bounded, correlated projection handed to a reflection request."
  @type projection :: %{required(String.t()) => term()}

  @doc "The projection for a session whose host supplied no gateway evidence."
  @spec not_supplied() :: projection()
  def not_supplied, do: @not_supplied

  @doc """
  Projects host-supplied gateway evidence against the session's own entries.

  `evidence` is the host's JSON-shaped map; `entries` is the durable
  transcript. Returns a bounded map that names provenance, freshness,
  missingness, per-request correlation and a side-by-side reconciliation.
  Anything that is not a usable map — `nil`, a string, an empty map — becomes
  an explicit `"not supplied"` or `"unusable"` projection rather than an
  exception or a silently empty section.
  """
  @spec project(evidence :: term(), entries :: [Entry.t()]) :: projection()
  def project(evidence, entries \\ [])

  def project(nil, _entries), do: @not_supplied
  def project(evidence, _entries) when evidence == %{}, do: @not_supplied

  def project(%{"availability" => "not supplied"}, _entries), do: @not_supplied

  def project(evidence, entries) when is_map(evidence) and is_list(entries) do
    records = records(evidence)
    requests = requests(entries)
    correlation = correlate(requests, records)

    %{
      "availability" => "supplied",
      "provenance" => provenance(evidence),
      "freshness" => freshness(evidence, entries),
      "correlation" => correlation,
      "reconciliation" => reconciliation(evidence, records, requests, entries),
      "problems" => problems(evidence, records, correlation),
      "rule" =>
        "gateway and local figures are two observations of the same requests. Compare them; " <>
          "never add them, and never treat a missing gateway record as a zero."
    }
  end

  # A host that hands over something that is not a map has a bug, and saying so
  # beats quietly reporting no gateway at all: "there is no gateway" and "the
  # gateway record could not be read" are the difference between an absence that
  # means nothing and one that means something.
  def project(evidence, _entries) do
    Map.merge(@not_supplied, %{
      "availability" => "unusable",
      "note" => "host evidence was not a JSON object",
      "received_type" => type_of(evidence)
    })
  end

  @doc """
  The gateway records, normalized, or `[]` when none were supplied.

  Public because a host reconciling its own ledger wants the same
  normalization the reflection projection used, rather than a second reading
  of the same map.
  """
  @spec records(evidence :: term()) :: [map()]
  def records(%{"records" => records}) when is_list(records) do
    records
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn record ->
      record
      |> Map.take(["request_id", "observed_at", "status" | @counters])
      |> Map.put("request_id", identifier(record["request_id"]))
    end)
  end

  def records(_evidence), do: []

  defp requests(entries) do
    entries
    |> Enum.filter(&(&1.type == :request))
    |> Enum.map(
      &%{
        "request_id" => identifier(&1.payload["id"]),
        "entry_id" => &1.id,
        "seq" => &1.seq,
        "kind" => &1.payload["kind"]
      }
    )
  end

  defp provenance(evidence) do
    %{
      "source" => identifier(evidence["source"]) || "unattributed",
      "instance" => identifier(evidence["instance"]),
      "scope" => evidence["scope"],
      "collected_at" => identifier(evidence["collected_at"]),
      "declared_window" => window(evidence["window"]),
      "attributed" => is_binary(evidence["source"]) and evidence["source"] != ""
    }
  end

  defp window(%{"from" => from, "to" => to}),
    do: %{"from" => identifier(from), "to" => identifier(to)}

  defp window(_window), do: nil

  # Freshness is a comparison, not a timestamp: what matters is whether the gateway
  # was still collecting when the session made its last request. A gateway whose
  # window closed first has an excuse for every record it is missing, and a reader
  # who does not know that reads those absences as requests that never happened.
  defp freshness(evidence, entries) do
    latest = latest_entry_at(entries)
    collected = time(evidence["collected_at"])
    window_end = evidence |> Map.get("window", %{}) |> then(&(is_map(&1) and time(&1["to"])))
    edge = if match?(%DateTime{}, window_end), do: window_end, else: collected

    %{
      "collected_at" => iso(collected),
      "window_ends_at" => iso(if(match?(%DateTime{}, window_end), do: window_end)),
      "latest_local_entry_at" => iso(latest),
      "lag_ms" => lag(edge, latest),
      "covers_session" => covers?(edge, latest),
      "state" => freshness_state(edge, latest)
    }
  end

  defp covers?(%DateTime{} = edge, %DateTime{} = latest),
    do: DateTime.compare(edge, latest) != :lt

  defp covers?(_edge, _latest), do: nil

  defp lag(%DateTime{} = edge, %DateTime{} = latest),
    do: DateTime.diff(latest, edge, :millisecond)

  defp lag(_edge, _latest), do: nil

  defp freshness_state(%DateTime{} = edge, %DateTime{} = latest) do
    if DateTime.compare(edge, latest) == :lt, do: "behind_session", else: "covers_session"
  end

  defp freshness_state(_edge, _latest), do: "unknown"

  defp latest_entry_at([]), do: nil
  defp latest_entry_at(entries), do: entries |> Enum.map(& &1.at) |> Enum.max(DateTime)

  defp correlate(requests, records) do
    by_request = Enum.group_by(records, & &1["request_id"])
    local_ids = MapSet.new(requests, & &1["request_id"])

    turns =
      Enum.map(requests, fn request ->
        matches = Map.get(by_request, request["request_id"], [])

        Map.merge(request, %{
          "gateway_records" => length(matches),
          "matched" => matches != []
        })
      end)

    # A record with no id at all is counted as unidentified, not as belonging
    # to some other session: not knowing which request it describes is a
    # different failure from knowing it describes somebody else's.
    unmatched_records =
      records
      |> Enum.map(& &1["request_id"])
      |> Enum.filter(&(is_binary(&1) and not MapSet.member?(local_ids, &1)))
      |> Enum.uniq()

    duplicates =
      by_request
      |> Enum.filter(fn {id, matches} -> is_binary(id) and length(matches) > 1 end)
      |> Enum.map(&elem(&1, 0))

    %{
      "local_requests" => length(requests),
      "gateway_records" => length(records),
      "matched_requests" => Enum.count(turns, & &1["matched"]),
      "requests_without_gateway_record" =>
        turns |> Enum.reject(& &1["matched"]) |> Enum.map(& &1["entry_id"]) |> listed(),
      "gateway_records_without_request" => listed(unmatched_records),
      "duplicate_gateway_records" => listed(Enum.sort(duplicates)),
      "unidentified_gateway_records" => Enum.count(records, &is_nil(&1["request_id"])),
      "turns" => listed(turns)
    }
  end

  # The one place the two ledgers meet, and they meet as a comparison. The
  # gateway's own `"totals"` wins over a sum of its records when it supplies
  # one: an aggregate the gateway computed is what the gateway will bill, and
  # recomputing it here would quietly claim the records are complete.
  defp reconciliation(evidence, records, requests, entries) do
    gateway = gateway_totals(evidence, records)
    local = local_totals(entries, requests)

    %{
      "local" => local,
      "gateway" => gateway,
      "gateway_totals_source" =>
        if(is_map(evidence["totals"]), do: "declared", else: "summed_from_records"),
      "comparison" =>
        Map.new(@counters, fn counter ->
          {counter, compare(local[counter], gateway[counter])}
        end),
      "note" =>
        "local figures come from this session's own usage reports; gateway figures come from " <>
          "the host. They describe the same requests and are never summed."
    }
  end

  defp gateway_totals(%{"totals" => totals}, _records) when is_map(totals),
    do: Map.new(@counters, &{&1, number(totals[&1])})

  defp gateway_totals(_evidence, records) do
    Map.new(@counters, fn counter ->
      values = Enum.map(records, &number(&1[counter]))
      {counter, if(values != [] and Enum.all?(values, &is_number/1), do: Enum.sum(values))}
    end)
  end

  # Read from the same usage reports the rest of the projection counts, so a
  # disagreement is between the gateway and the transcript rather than between
  # the gateway and a third arithmetic.
  defp local_totals(entries, requests) do
    usages = for %Entry{usage: usage} <- entries, is_map(usage), do: usage

    Map.new(@counters, fn
      "tool_calls" ->
        {"tool_calls", Enum.count(entries, &(&1.type == :tool_result))}

      counter ->
        values = Enum.map(usages, &number(&1[counter]))
        {counter, if(values != [] and Enum.all?(values, &is_number/1), do: Enum.sum(values))}
    end)
    |> Map.put("requests", length(requests))
    |> Map.put("reported_usages", length(usages))
  end

  defp compare(local, gateway) when is_number(local) and is_number(gateway) do
    %{
      "local" => local,
      "gateway" => gateway,
      "difference" => gateway - local,
      "state" => if(gateway == local, do: "agrees", else: "differs")
    }
  end

  defp compare(local, gateway) do
    %{
      "local" => local,
      "gateway" => gateway,
      "difference" => nil,
      "state" => "unknown"
    }
  end

  # Everything a reader would otherwise have to notice by comparing two
  # sections. A problem is never fatal — the projection is still delivered —
  # but it is never silent either.
  defp problems(evidence, records, correlation) do
    [
      unattributed(evidence),
      undated(evidence),
      empty_records(records),
      unmatched(correlation),
      duplicated(correlation),
      unidentified(correlation)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp unattributed(evidence) do
    unless is_binary(evidence["source"]) and evidence["source"] != "" do
      problem("unattributed", "no source was named, so these numbers cannot be traced")
    end
  end

  defp undated(evidence) do
    unless is_binary(evidence["collected_at"]) or is_map(evidence["window"]) do
      problem("undated", "no collection time or window, so freshness cannot be established")
    end
  end

  defp empty_records([]),
    do: problem("no_records", "no per-request records, so nothing could be correlated")

  defp empty_records(_records), do: nil

  defp unmatched(%{"requests_without_gateway_record" => []}), do: nil

  defp unmatched(%{"requests_without_gateway_record" => ids}) do
    problem(
      "requests_without_gateway_record",
      "#{length(ids)} local request(s) have no gateway record; treat this as unknown, not zero"
    )
  end

  defp duplicated(%{"duplicate_gateway_records" => []}), do: nil

  defp duplicated(%{"duplicate_gateway_records" => ids}) do
    problem(
      "duplicate_gateway_records",
      "#{length(ids)} request id(s) appear in more than one gateway record; the gateway total " <>
        "may count a retry the transcript records once"
    )
  end

  defp unidentified(%{"unidentified_gateway_records" => 0}), do: nil

  defp unidentified(%{"unidentified_gateway_records" => count}) do
    problem(
      "unidentified_gateway_records",
      "#{count} gateway record(s) carry no request id and could not be correlated"
    )
  end

  defp problem(kind, detail), do: %{"kind" => kind, "detail" => detail}

  # Lists in this projection exist to be read, not to reproduce the ledger.
  # A session with a thousand requests would otherwise spend its whole
  # evidence budget listing ids.
  defp listed(values) when length(values) > @max_listed do
    %{
      "count" => length(values),
      "listed" => Enum.take(values, @max_listed),
      "truncated" => length(values) - @max_listed
    }
  end

  defp listed(values), do: values

  defp identifier(value) when is_binary(value) and value != "", do: value
  defp identifier(_value), do: nil

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _invalid -> nil
    end
  end

  defp time(%DateTime{} = value), do: value
  defp time(_value), do: nil

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: nil

  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_number(value), do: "number"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(_value), do: "unknown"
end
