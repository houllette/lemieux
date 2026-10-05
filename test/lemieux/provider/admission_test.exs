defmodule Lemieux.Provider.AdmissionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider.Admission
  alias Lemieux.ProviderLimiter

  # Records every call it receives, so the wrappers can be shown to hand each
  # one to the module named in the pair, with that pair's ref, and nothing else.
  defmodule Recorder do
    @behaviour Admission

    @impl Admission
    def checkout(ref, key, root_id, estimated_tokens) do
      send(ref, {:checkout, key, root_id, estimated_tokens})
      {:ok, {:lease, ref, key}}
    end

    @impl Admission
    def release({:lease, ref, key}) do
      send(ref, {:release, key})
      :ok
    end

    @impl Admission
    def reconcile({:lease, ref, key}, actual_tokens) do
      send(ref, {:reconcile, key, actual_tokens})
      :ok
    end

    @impl Admission
    def penalize(ref, key, retry_after_ms) do
      send(ref, {:penalize, key, retry_after_ms})
      :ok
    end
  end

  test "dispatches each call to the module in the pair, with its ref" do
    admission = {Recorder, self()}

    assert {:ok, lease} = Admission.checkout(admission, :credential, "root-1", 12)
    assert_receive {:checkout, :credential, "root-1", 12}

    assert :ok = Admission.reconcile(admission, lease, 7)
    assert_receive {:reconcile, :credential, 7}

    assert :ok = Admission.release(admission, lease)
    assert_receive {:release, :credential}

    assert :ok = Admission.penalize(admission, :credential, 500)
    assert_receive {:penalize, :credential, 500}
  end

  # The shipped limiter is itself an implementation of the behaviour, so the
  # contract and the default cannot drift apart: a callback added to one
  # without the other fails to compile.
  test "the shipped limiter implements the behaviour and works through the wrappers" do
    assert Admission in behaviours(ProviderLimiter)

    limiter = start_supervised!({ProviderLimiter, max_concurrency: 1, tokens_per_interval: 100})
    admission = {ProviderLimiter, limiter}

    assert {:ok, lease} = Admission.checkout(admission, :provider, "root", 80)
    assert %{active: 1} = ProviderLimiter.snapshot(limiter).buckets.provider

    assert :ok = Admission.reconcile(admission, lease, 20)
    assert :ok = Admission.release(admission, lease)
    assert :ok = Admission.penalize(admission, :provider, 0)

    # Reconciled down to the twenty actually spent, then released: the bucket
    # got sixty of its eighty back. A wrapper that dropped the lease or the
    # tokens on the floor would leave it at twenty.
    assert %{active: 0, available_tokens: available} =
             ProviderLimiter.snapshot(limiter).buckets.provider

    assert_in_delta available, 80, 1
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
