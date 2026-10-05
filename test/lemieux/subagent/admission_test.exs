defmodule Lemieux.Subagent.AdmissionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Subagent.Admission

  test "reserves the full group atomically and admits within runtime capacity" do
    admission = start_supervised!({Admission, max_active_runtime: 1, max_active_root: 3})
    children = [child("one", :one, 0.2), child("two", :two, 0.3)]

    assert :ok = Admission.reserve(admission, "root", self(), "group", self(), children, 1.0)
    assert_receive {:subagent_admitted, "one"}
    refute_receive {:subagent_admitted, "two"}

    Admission.release(admission, "one", 0.1)
    assert_receive {:subagent_admitted, "two"}
    Admission.release(admission, "two", 0.25)

    assert %{active: 0, queued: 0, roots: %{"root" => root}} = Admission.snapshot(admission)
    assert_in_delta root.spent_usd, 0.35, 0.0001
    assert root.reserved_usd == 0.0
  end

  test "rejects duplicate live work and over-budget batches before any child starts" do
    admission = start_supervised!({Admission, max_active_runtime: 1, max_active_root: 3})
    first = child("one", :same, 0.3)

    assert :ok = Admission.reserve(admission, "root", self(), "first", self(), [first], 0.5)
    assert_receive {:subagent_admitted, "one"}

    assert {:error, {:duplicate_work, :same}} =
             Admission.reserve(
               admission,
               "other-root",
               self(),
               "duplicate",
               self(),
               [child("two", :same, 0.1)],
               1.0
             )

    assert {:error, %{reason: :tree_budget}} =
             Admission.reserve(
               admission,
               "root",
               self(),
               "too-expensive",
               self(),
               [child("two", :other, 0.3)],
               0.5
             )

    assert %{active: 1, queued: 0, duplicates: 1} = Admission.snapshot(admission)
  end

  test "rejects duplicate work inside one batch atomically" do
    admission = start_supervised!({Admission, max_active_runtime: 8, max_active_root: 3})

    assert {:error, :duplicate_work_in_group} =
             Admission.reserve(
               admission,
               "root",
               self(),
               "group",
               self(),
               [child("one", :same, 0.1), child("two", :same, 0.1)],
               1.0
             )

    assert %{active: 0, queued: 0, duplicates: 0} = Admission.snapshot(admission)
    refute_receive {:subagent_admitted, _child_id}
  end

  test "a dead group releases active and queued reservations without duplicate spend" do
    admission = start_supervised!({Admission, max_active_runtime: 1, max_active_root: 3})
    group = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok =
             Admission.reserve(
               admission,
               "root",
               self(),
               "group",
               group,
               [child("one", :one, 0.1), child("two", :two, 0.1)],
               1.0
             )

    Process.exit(group, :kill)
    LemieuxTest.Sync.state(admission, fn state -> map_size(state.active) == 0 end)

    assert %{active: 0, queued: 0, duplicates: 0} = Admission.snapshot(admission)
  end

  test "enforces the root child ceiling across groups" do
    admission = start_supervised!({Admission, max_active_runtime: 8, max_active_root: 3})

    assert :ok =
             Admission.reserve(
               admission,
               "root",
               self(),
               "first",
               self(),
               [child("one", :one, 0.1), child("two", :two, 0.1)],
               1.0
             )

    assert {:error, {:root_limit, 3}} =
             Admission.reserve(
               admission,
               "root",
               self(),
               "second",
               self(),
               [child("three", :three, 0.1), child("four", :four, 0.1)],
               1.0
             )
  end

  # A route that cannot price a child bounds the whole tree in requests
  # instead. Dollars are not a currency such a route can be held to, so without
  # this dimension a quota tree was bounded per child and not in total — which
  # is what let one session fire `delegate` ten times over.
  describe "a tree bounded in requests" do
    test "refuses a fan-out that would exceed the ceiling, before any child starts" do
      admission = start_supervised!({Admission, max_active_runtime: 2, max_active_root: 6})
      quota = fn id, key, requests -> %{child(id, key, 0.0) | reserved_requests: requests} end

      assert :ok =
               Admission.reserve(
                 admission,
                 "root",
                 self(),
                 "first",
                 self(),
                 [quota.("one", :one, 8), quota.("two", :two, 8)],
                 1.0,
                 20
               )

      assert_receive {:subagent_admitted, "one"}

      assert {:error, {:root_request_budget_exhausted, %{ceiling: 20, incoming: 8}}} =
               Admission.reserve(
                 admission,
                 "root",
                 self(),
                 "second",
                 self(),
                 [quota.("three", :three, 8)],
                 1.0,
                 20
               )

      refute_receive {:subagent_admitted, "three"}
    end

    test "a tree that declared no request ceiling is not constrained by one" do
      admission = start_supervised!({Admission, max_active_runtime: 1, max_active_root: 3})
      quota = %{child("one", :one, 0.0) | reserved_requests: 1_000}

      assert :ok =
               Admission.reserve(admission, "root", self(), "group", self(), [quota], 1.0)

      assert_receive {:subagent_admitted, "one"}
    end

    test "releasing gives the requests back, charged at the reservation" do
      admission = start_supervised!({Admission, max_active_runtime: 1, max_active_root: 3})
      quota = %{child("one", :one, 0.0) | reserved_requests: 6}

      assert :ok = Admission.reserve(admission, "root", self(), "g", self(), [quota], 1.0, 12)
      assert_receive {:subagent_admitted, "one"}

      Admission.release(admission, "one", 0.0)

      assert %{roots: %{"root" => root}} = Admission.snapshot(admission)
      assert root.reserved_requests == 0

      # Charged in full rather than measured: a child's own request count is
      # not reported back here, so an upper bound is the honest ceiling.
      assert root.spent_requests == 6
    end
  end

  defp child(id, duplicate_key, cost) do
    %{id: id, duplicate_key: duplicate_key, reserved_cost_usd: cost, reserved_requests: nil}
  end
end
