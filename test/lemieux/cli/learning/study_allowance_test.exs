defmodule Lemieux.CLI.Learning.StudyAllowanceTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.StudyAllowance
  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  @moduletag :tmp_dir

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

    assert_receive {:dispatch, dispatch}
    dispatch_monitor = Process.monitor(dispatch)
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
end
