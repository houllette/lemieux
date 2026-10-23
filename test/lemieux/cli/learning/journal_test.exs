defmodule Lemieux.CLI.Learning.JournalTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.RepositoryContext.Worker
  @moduletag :tmp_dir

  test "a killed worker cannot strand undo behind its dead lock", %{tmp_dir: root} do
    owner = self()

    task =
      Task.async(fn ->
        Worker.run(
          fn ->
            Journal.update(root, fn _control ->
              send(owner, {:locked, self()})

              receive do
                :never -> {:error, :unexpected}
              after
                60_000 -> {:error, :fixture_expired}
              end
            end)
          end,
          60_000
        )
      end)

    assert_receive {:locked, worker}
    Process.exit(worker, :kill)
    assert {:error, :worker_failed} = Task.await(task)
    assert :ok = Journal.update(root, &{:ok, Map.put(&1, "enabled", false)})
    assert {:ok, %{"enabled" => false}} = Journal.control(root)
  end

  test "live and legacy ambiguous locks refuse a second writer", %{tmp_dir: root} do
    owner = self()

    task =
      Task.async(fn ->
        Journal.update(root, fn control ->
          send(owner, :locked)

          receive do
            :release -> {:ok, control}
          after
            60_000 -> {:error, :fixture_expired}
          end
        end)
      end)

    assert_receive :locked
    assert {:error, _} = Journal.update(root, &{:ok, Map.put(&1, "enabled", false)})
    send(task.pid, :release)
    assert :ok = Task.await(task)
    File.mkdir!(Path.join(root, "control.lock"))
    assert {:error, _} = Journal.update(root, &{:ok, Map.put(&1, "enabled", false)})
    assert {:ok, %{"enabled" => true}} = Journal.control(root)
  end
end
