defmodule Lemieux.Agent.ResourceTest do
  use ExUnit.Case, async: true
  alias Lemieux.Agent.Resource

  test "an acquisition worker stops when its caller is cancelled" do
    test = self()

    caller =
      spawn(fn ->
        Resource.acquire(
          fn _owner ->
            send(test, {:acquiring, self()})

            receive do
              :complete -> {:ok, :resource}
            after
              60_000 -> {:error, :acquisition_timeout}
            end
          end,
          fn _resource -> :ok end
        )
      end)

    assert_receive {:acquiring, worker}
    monitor = Process.monitor(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
  end

  test "an acquisition timeout stops the worker and reconciles partial effects" do
    owner = self()

    assert {:error, :resource_start_timeout} =
             Resource.acquire(
               fn _ ->
                 send(owner, {:worker, self()})

                 receive do
                   :never -> {:ok, :resource}
                 end
               end,
               fn _ -> flunk("no complete handle exists") end,
               timeout_ms: 30,
               abort: fn ->
                 send(owner, :aborted)
                 :ok
               end
             )

    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    assert_receive :aborted
  end

  test "a returned handle is released exactly once after owner loss" do
    owner = self()

    caller =
      spawn(fn ->
        {:ok, :resource, guardian} =
          Resource.acquire(
            fn _ -> {:ok, :resource} end,
            fn :resource ->
              send(owner, :released)
              :ok
            end
          )

        send(owner, {:guardian, guardian})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:guardian, guardian}
    monitor = Process.monitor(guardian)
    Process.exit(caller, :kill)
    assert_receive :released
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}
    refute_receive :released, 50
  end

  test "cleanup failure is reported rather than claiming release" do
    assert {:ok, :resource, guardian} =
             Resource.acquire(
               fn _ -> {:ok, :resource} end,
               fn _ -> {:error, :not_restored} end
             )

    assert {:error, :resource_cleanup_failed} = Resource.release(guardian)
  end
end
