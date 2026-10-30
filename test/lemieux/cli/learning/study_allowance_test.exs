defmodule Lemieux.CLI.Learning.StudyAllowanceTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.Recording
  alias Lemieux.CLI.Learning.StudyAllowance
  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  @moduletag :tmp_dir

  test "asset roles retain physical detail while sharing the ordinary proposer and critic allowance",
       %{tmp_dir: dir} do
    limits = [max_requests: 2, max_tokens: 100, max_time_ms: 600_000]
    raw = Scripted.new(List.duplicate(Scripted.complete("ok", usage: usage()), 3))
    meter = start_supervised!({Agent, fn -> %{} end})
    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, allowance} = StudyAllowance.open(Path.join(dir, "allowance"), limits)

    for role <- [:asset_proposer, :asset_critic] do
      recording = Recording.new(meter, raw, role: role, cost_mode: :quota)

      assert :ok =
               Provider.run(StudyAllowance.provider(allowance, role, recording), request, fn _ ->
                 :ok
               end)
    end

    snapshot = StudyAllowance.snapshot(allowance)
    assert snapshot["accounting"]["requests"] == 2
    assert snapshot["accounting"]["tokens"] == 14

    assert Enum.sort(Enum.map(snapshot["records"], fn {_, record} -> record["role"] end)) ==
             ["critic", "proposer"]

    assert meter |> Agent.get(&Map.values/1) |> Enum.map(& &1["role"]) |> Enum.sort() ==
             ["asset_critic", "asset_proposer"]

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(allowance, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 2
    assert :ok = StudyAllowance.close(allowance)
  end

  test "all stages and roles consume one durable allowance without resetting it", %{tmp_dir: dir} do
    limits = [max_requests: 2, max_tokens: 100, max_time_ms: 60_000]
    raw = Scripted.new(List.duplicate(Scripted.complete("ok", usage: usage()), 3))
    request = Request.new("test:model", params: [max_tokens: 16])
    path = Path.join(dir, "allowance")
    assert {:ok, first} = StudyAllowance.open(path, limits)
    assert {:error, _} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    assert :ok = StudyAllowance.close(first)

    assert {:ok, second} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(second, :proposer, raw), request, fn _ ->
               :ok
             end)

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(second, :probe, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 2
    assert StudyAllowance.snapshot(second)["accounting"]["tokens"] == 14
    assert :ok = StudyAllowance.close(second)
    assert {:error, _} = StudyAllowance.open(path, Keyword.put(limits, :max_requests, 3))
  end

  test "unknown accounting survives reopen and prevents future physical dispatch", %{tmp_dir: dir} do
    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 60_000]

    raw =
      Scripted.new([
        Scripted.error(:unavailable),
        Scripted.complete("must not run", usage: usage())
      ])

    request = Request.new("test:model", params: [max_tokens: 16])
    path = Path.join(dir, "allowance")
    assert {:ok, first} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :reflection, raw), request, fn _ ->
               :ok
             end)

    assert :ok = StudyAllowance.close(first)
    assert {:ok, restored} = StudyAllowance.open(path, limits)

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 1
    assert :ok = StudyAllowance.close(restored)
  end

  test "token limits refuse dispatch, and symlinked state is refused", %{tmp_dir: dir} do
    raw = Scripted.new([Scripted.complete("must not run", usage: usage())])
    request = Request.new("test:model", params: [max_tokens: 1000])
    path = Path.join(dir, "allowance")

    assert {:ok, allowance} =
             StudyAllowance.open(path, max_requests: 3, max_tokens: 100, max_time_ms: 60_000)

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(allowance, :task, raw), request, fn _ -> :ok end)

    assert Scripted.requests(raw) == []
    assert :ok = StudyAllowance.close(allowance)
    File.rename!(Path.join(path, "controller.json"), Path.join(dir, "foreign.json"))
    File.ln_s!(Path.join(dir, "foreign.json"), Path.join(path, "controller.json"))

    assert {:error, _} =
             StudyAllowance.open(path, max_requests: 3, max_tokens: 100, max_time_ms: 60_000)
  end

  test "the original deadline survives a stage restart", %{tmp_dir: dir} do
    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 60_000]
    path = Path.join(dir, "allowance")
    assert {:ok, first} = StudyAllowance.open(path, limits)
    assert :ok = StudyAllowance.close(first)
    checkpoint = Path.join(path, "controller.json")
    value = checkpoint |> File.read!() |> JSON.decode!()

    value =
      value
      |> Map.put("deadline_ms", System.system_time(:millisecond) - 1)
      |> Journal.seal()

    File.write!(checkpoint, JSON.encode!(value))
    assert {:ok, restored} = StudyAllowance.open(path, limits)
    raw = Scripted.new([Scripted.complete("must not run", usage: usage())])
    request = Request.new("test:model", params: [max_tokens: 16])

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert Scripted.requests(raw) == []
    assert :ok = StudyAllowance.close(restored)
  end

  test "cancelled dispatches retain an uncertain charge and stop later stages", %{tmp_dir: dir} do
    owner = self()

    raw =
      Scripted.new([
        fn _request ->
          send(owner, {:dispatch, self()})

          # A monitor signal and the guardian's exit signal have different
          # senders. Acknowledge this caller's later message before it kills
          # the owner, so the monitor is installed before the dispatch dies.
          receive do
            :monitored -> send(owner, {:dispatch_monitored, self()})
          end

          receive do
            :never -> Scripted.complete("late", usage: usage())
          after
            60_000 -> Scripted.complete("timer must not win", usage: usage())
          end
        end
      ])

    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 180_000]
    path = Path.join(dir, "allowance")
    assert {:ok, first} = StudyAllowance.open(path, limits)
    provider = StudyAllowance.provider(first, :probe, raw)

    {worker, monitor} =
      spawn_monitor(fn ->
        Provider.run(provider, Request.new("test:model", params: [max_tokens: 16]), fn _ ->
          :ok
        end)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:dispatch, dispatch}
    dispatch_monitor = Process.monitor(dispatch)
    send(dispatch, :monitored)
    assert_receive {:dispatch_monitored, ^dispatch}
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch, :killed}
    assert StudyAllowance.snapshot(first)["accounting"]["tokens"] == nil
    assert :ok = StudyAllowance.close(first)
    assert {:ok, restored} = StudyAllowance.open(path, limits)

    assert {:error, _} =
             Provider.run(
               StudyAllowance.provider(restored, :task, raw),
               Request.new("test:model", params: [max_tokens: 16]),
               fn _ -> :ok end
             )

    assert length(Scripted.requests(raw)) == 1
    assert :ok = StudyAllowance.close(restored)
  end

  defp usage, do: %{"input_tokens" => 4, "output_tokens" => 3}

  test "a reserve cannot reopen an expired allowance or change its deadline", %{tmp_dir: dir} do
    path = Path.join(dir, "expired-reserve")
    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 600_000]

    raw =
      Scripted.new([Scripted.error(:unavailable), Scripted.complete("forbidden", usage: usage())])

    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, first} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    [{id, _record}] = Map.to_list(StudyAllowance.snapshot(first)["records"])
    assert :ok = StudyAllowance.close(first)
    checkpoint_path = Path.join(path, "controller.json")

    expired =
      checkpoint_path
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("deadline_ms", System.system_time(:millisecond) - 1)
      |> Journal.seal()

    File.write!(checkpoint_path, JSON.encode!(expired))
    assert {:ok, _} = StudyAllowance.reserve_unknown(path, limits, id, 200, "approval")
    assert {:ok, restored} = StudyAllowance.open(path, limits)
    assert StudyAllowance.snapshot(restored)["deadline_ms"] == expired["deadline_ms"]

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 1
    assert :ok = StudyAllowance.close(restored)
  end

  test "altered reserves, changed unknown records and false upper totals refuse reopening", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "tampered-reserve")
    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 600_000]
    raw = Scripted.new([Scripted.error(:unavailable)])
    assert {:ok, first} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(
               StudyAllowance.provider(first, :task, raw),
               Request.new("test:model", params: [max_tokens: 16]),
               fn _ -> :ok end
             )

    [{id, _record}] = Map.to_list(StudyAllowance.snapshot(first)["records"])
    assert :ok = StudyAllowance.close(first)
    assert {:ok, _} = StudyAllowance.reserve_unknown(path, limits, id, 200, "approval")
    registration = Path.join(path, "authorization.json")
    original = registration |> File.read!() |> JSON.decode!()
    checkpoint = original["checkpoint"]

    changed_receipt =
      checkpoint["token_reserves"][id]
      |> Map.put("record_sha256", String.duplicate("0", 64))
      |> Journal.seal()

    for changed <- [
          put_in(checkpoint, ["token_reserves", id, "tokens"], 1),
          put_in(checkpoint, ["token_reserves", id], changed_receipt),
          put_in(checkpoint, ["records", id, "role"], "reflection"),
          put_in(checkpoint, ["limits", "cost_mode"], "metered"),
          Map.put(checkpoint, "budget_tokens", 0),
          Map.put(checkpoint, "schema_version", 1)
        ] do
      envelope = original |> Map.put("checkpoint", Journal.seal(changed)) |> Journal.seal()
      File.write!(registration, JSON.encode!(envelope))
      assert {:error, _} = StudyAllowance.open(path, limits)
    end
  end

  test "reserves refuse already measured tasks and unmeasured learning calls", %{tmp_dir: dir} do
    limits = [max_requests: 3, max_tokens: 1000, max_time_ms: 600_000]

    for {role, step} <- [
          {:reflection, Scripted.error(:unavailable)},
          {:task, Scripted.complete("known", usage: usage())}
        ] do
      path = Path.join(dir, to_string(role))
      assert {:ok, first} = StudyAllowance.open(path, limits)

      assert :ok =
               Provider.run(
                 StudyAllowance.provider(first, role, Scripted.new([step])),
                 Request.new("test:model", params: [max_tokens: 16]),
                 fn _ -> :ok end
               )

      [{id, _record}] = Map.to_list(StudyAllowance.snapshot(first)["records"])
      assert :ok = StudyAllowance.close(first)
      assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, id, 200, "approval")
    end
  end

  test "approved reserve preserves unknown facts across restart and covers only its exact request",
       %{tmp_dir: dir} do
    path = Path.join(dir, "reserved-unknown")
    limits = [max_requests: 5, max_tokens: 1000, max_time_ms: 600_000]

    raw =
      Scripted.new([
        Scripted.error(:unavailable),
        Scripted.complete("ok", usage: usage()),
        Scripted.error(:unavailable),
        Scripted.complete("forbidden", usage: usage())
      ])

    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, first} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    prior = StudyAllowance.snapshot(first)
    [{id, record}] = Map.to_list(prior["records"])
    assert :ok = StudyAllowance.close(first)
    archived = File.read!(Path.join(path, "controller.json"))

    assert {:ok, receipt} =
             StudyAllowance.reserve_unknown(path, limits, id, 200, "explicit user approval")

    assert receipt["record_sha256"] == Lemieux.Contract.digest(record)
    assert {:ok, restored} = StudyAllowance.open(path, limits)
    current = StudyAllowance.snapshot(restored)
    assert current["records"] == prior["records"]
    assert current["accounting"] == prior["accounting"]
    assert current["budget_tokens"] == 200
    assert current["deadline_ms"] == prior["deadline_ms"]
    assert current["schema_version"] == 2

    assert :ok =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert StudyAllowance.snapshot(restored)["budget_tokens"] == 207
    assert StudyAllowance.snapshot(restored)["accounting"]["tokens"] == nil
    assert :ok = StudyAllowance.close(restored)
    assert {:ok, again} = StudyAllowance.open(path, limits)
    assert StudyAllowance.snapshot(again)["budget_tokens"] == 207

    assert :ok =
             Provider.run(StudyAllowance.provider(again, :task, raw), request, fn _ -> :ok end)

    assert StudyAllowance.snapshot(again)["budget_tokens"] == nil

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(again, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 3
    assert :ok = StudyAllowance.close(again)
    assert File.read!(Path.join(path, "controller.json")) == archived
    assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, id, 200, "duplicate")
  end

  test "reserves consume the existing token cap and require explicit inactive ownership", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "reserve-cap")
    limits = [max_requests: 3, max_tokens: 100, max_time_ms: 600_000]

    raw =
      Scripted.new([Scripted.error(:unavailable), Scripted.complete("forbidden", usage: usage())])

    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, first} = StudyAllowance.open(path, limits)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    [{id, _record}] = Map.to_list(StudyAllowance.snapshot(first)["records"])
    assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, id, 100, "locked")
    assert :ok = StudyAllowance.close(first)
    assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, id, 100, "")
    assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, "missing", 100, "approval")
    assert {:error, _} = StudyAllowance.reserve_unknown(path, limits, id, 1, "under reservation")
    assert {:ok, _} = StudyAllowance.reserve_unknown(path, limits, id, 100, "explicit approval")
    assert {:ok, restored} = StudyAllowance.open(path, limits)
    assert StudyAllowance.snapshot(restored)["budget_tokens"] == 100

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 1
    assert :ok = StudyAllowance.close(restored)
  end

  test "neither registration format persists a checkpoint that its reader cannot reopen", %{
    tmp_dir: dir
  } do
    alias Lemieux.CLI.Learning.StudyRegistration
    path = Path.join(dir, "persistence-bound")
    limits = [max_requests: 2, max_tokens: 100, max_time_ms: 60_000]
    assert {:ok, first} = StudyAllowance.open(path, limits)
    assert :ok = StudyAllowance.close(first)
    assert {:ok, checkpoint, persist} = StudyRegistration.load(path, limits)
    archive = File.read!(Path.join(path, "controller.json"))
    oversized = checkpoint |> Map.put("extra", String.duplicate("x", 4_194_304)) |> Journal.seal()
    assert {:error, :study_checkpoint_too_large} = persist.(oversized)
    assert File.read!(Path.join(path, "controller.json")) == archive

    next = Keyword.put(limits, :max_requests, 3)
    assert {:ok, _} = StudyAllowance.amend(path, limits, next, "explicit approval")
    assert {:ok, checkpoint, persist} = StudyRegistration.load(path, next)
    registration = File.read!(Path.join(path, "authorization.json"))
    oversized = checkpoint |> Map.put("extra", String.duplicate("x", 4_194_304)) |> Journal.seal()
    assert {:error, :study_checkpoint_too_large} = persist.(oversized)
    assert File.read!(Path.join(path, "authorization.json")) == registration
    assert {:ok, restored} = StudyAllowance.open(path, next)
    assert :ok = StudyAllowance.close(restored)
  end

  test "amendment chains reject decreased limits, changed history, malformed envelopes and unsafe paths",
       %{tmp_dir: dir} do
    path = Path.join(dir, "chain")
    first = [max_requests: 2, max_tokens: 100, max_time_ms: 60_000]
    second = [max_requests: 4, max_tokens: 200, max_time_ms: 120_000]
    third = [max_requests: 5, max_tokens: 300, max_time_ms: 180_000]
    assert {:ok, initial} = StudyAllowance.open(path, first)
    deadline = StudyAllowance.snapshot(initial)["deadline_ms"]
    assert :ok = StudyAllowance.close(initial)
    assert {:error, _} = StudyAllowance.amend(path, first, second, "")
    assert {:ok, _} = StudyAllowance.amend(path, first, second, "approval one")
    assert {:error, _} = StudyAllowance.amend(path, second, first, "decreased")
    assert {:ok, _} = StudyAllowance.amend(path, second, third, "approval two")
    assert {:ok, restored} = StudyAllowance.open(path, third)
    assert StudyAllowance.snapshot(restored)["deadline_ms"] == deadline + 120_000
    assert :ok = StudyAllowance.close(restored)

    registration = Path.join(path, "authorization.json")
    bytes = File.read!(registration)
    value = JSON.decode!(bytes)
    [one, two] = value["amendments"]
    changed = two |> Map.put("previous_sha256", String.duplicate("0", 64)) |> Journal.seal()

    File.write!(
      registration,
      JSON.encode!(Journal.seal(Map.put(value, "amendments", [one, changed])))
    )

    assert {:error, _} = StudyAllowance.open(path, third)
    File.write!(registration, JSON.encode!(Journal.seal(Map.put(value, "original", nil))))
    assert {:error, _} = StudyAllowance.open(path, third)

    assert {:error, _} =
             StudyAllowance.amend(path, third, Keyword.put(third, :max_requests, 6), "invalid")

    File.write!(registration, bytes)
    File.rename!(registration, Path.join(dir, "foreign.json"))
    File.ln_s!(Path.join(dir, "foreign.json"), registration)
    assert {:error, _} = StudyAllowance.open(path, third)

    assert {:error, _} =
             StudyAllowance.amend(path, third, Keyword.put(third, :max_requests, 6), "unsafe")
  end

  test "the bounded checkpoint accommodates 7500 physical receipts and rejects excess records", %{
    tmp_dir: dir
  } do
    alias Lemieux.Learning.Controller.Checkpoint
    path = Path.join(dir, "capacity")

    assert {:ok, allowance} =
             StudyAllowance.open(path,
               max_requests: 7500,
               max_tokens: 100_000_000,
               max_time_ms: 86_400_000
             )

    raw = Scripted.new([Scripted.complete("ok", usage: usage())])

    assert :ok =
             Provider.run(
               StudyAllowance.provider(allowance, :task, raw),
               Request.new("test:model", params: [max_tokens: 16]),
               fn _ -> :ok end
             )

    snapshot = StudyAllowance.snapshot(allowance)
    [record] = Map.values(snapshot["records"])

    records =
      Map.new(1..7500, fn i ->
        id = "attempt/" <> Lemieux.Contract.sha256(Integer.to_string(i))
        {id, Map.put(record, "id", id)}
      end)

    large = snapshot |> Map.put("records", records) |> Journal.seal()
    assert byte_size(JSON.encode!(large)) > 2_097_152
    assert :ok = Checkpoint.verify(large, snapshot["job_id"], 8192)
    assert {:error, _} = Checkpoint.verify(large, snapshot["job_id"], 4096)
    assert :ok = StudyAllowance.close(allowance)
  end

  test "an explicit amendment preserves charges and extends time from the original start", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "amendment")
    before = [max_requests: 2, max_tokens: 100, max_time_ms: 60_000]
    after_limits = [max_requests: 4, max_tokens: 200, max_time_ms: 120_000]
    raw = Scripted.new([Scripted.complete("ok", usage: usage())])
    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, first} = StudyAllowance.open(path, before)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    prior = StudyAllowance.snapshot(first)
    assert {:error, _} = StudyAllowance.amend(path, before, after_limits, "explicit approval")
    assert :ok = StudyAllowance.close(first)
    original_bytes = File.read!(Path.join(path, "controller.json"))
    assert {:ok, receipt} = StudyAllowance.amend(path, before, after_limits, "explicit approval")
    assert receipt["prior_limits"]["max_requests"] == 2
    assert receipt["limits"]["max_requests"] == 4
    assert File.read!(Path.join(path, "controller.json")) == original_bytes
    assert {:error, _} = StudyAllowance.open(path, before)
    assert {:error, _} = StudyAllowance.amend(path, before, after_limits, "stale approval")
    assert {:ok, restored} = StudyAllowance.open(path, after_limits)
    current = StudyAllowance.snapshot(restored)
    assert current["records"] == prior["records"]
    assert current["accounting"] == prior["accounting"]
    assert current["deadline_ms"] == prior["deadline_ms"] + 60_000
    assert :ok = StudyAllowance.close(restored)
    assert {:ok, again} = StudyAllowance.open(path, after_limits)
    assert StudyAllowance.snapshot(again)["deadline_ms"] == current["deadline_ms"]
    assert :ok = StudyAllowance.close(again)
  end

  test "amending limits never resolves unknown usage or resets its request", %{tmp_dir: dir} do
    path = Path.join(dir, "unknown-amendment")
    before = [max_requests: 2, max_tokens: 100, max_time_ms: 60_000]
    after_limits = [max_requests: 4, max_tokens: 200, max_time_ms: 120_000]

    raw =
      Scripted.new([Scripted.error(:unavailable), Scripted.complete("forbidden", usage: usage())])

    request = Request.new("test:model", params: [max_tokens: 16])
    assert {:ok, first} = StudyAllowance.open(path, before)

    assert :ok =
             Provider.run(StudyAllowance.provider(first, :task, raw), request, fn _ -> :ok end)

    prior = StudyAllowance.snapshot(first)
    assert :ok = StudyAllowance.close(first)
    assert {:ok, _} = StudyAllowance.amend(path, before, after_limits, "explicit approval")
    assert {:ok, restored} = StudyAllowance.open(path, after_limits)
    assert StudyAllowance.snapshot(restored)["records"] == prior["records"]
    assert StudyAllowance.snapshot(restored)["accounting"]["requests"] == 1
    assert StudyAllowance.snapshot(restored)["accounting"]["tokens"] == nil

    assert {:error, _} =
             Provider.run(StudyAllowance.provider(restored, :task, raw), request, fn _ -> :ok end)

    assert length(Scripted.requests(raw)) == 1
    assert :ok = StudyAllowance.close(restored)
  end
end
