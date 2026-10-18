defmodule Lemieux.Asset.ProposalTest do
  use ExUnit.Case, async: true

  alias Lemieux.Asset.Proposal
  alias Lemieux.Asset.Registry
  alias Lemieux.Asset.Version

  test "activates only an approved scoped proposal and records its parent and rollback target" do
    assert {:ok, parent} =
             Version.new(%{
               type: :project_instruction,
               layer: :project,
               scope: :project,
               project_id: "project",
               content: "Run focused tests."
             })

    assert {:ok, version} =
             Version.new(%{
               type: :project_instruction,
               layer: :project,
               scope: :project,
               project_id: "project",
               parent_id: parent.id,
               rollback_target_id: parent.id,
               motivating_feedback_ids: ["fb_1"],
               content: "Run focused tests and the formatter."
             })

    proposal = Proposal.new(version)
    assert {:error, :approval_required} = Registry.activate(Registry.new(), proposal)

    assert {:ok, approved} = Proposal.approve(proposal, %{"type" => "human", "id" => "owner"})
    assert {:ok, registry, activation} = Registry.activate(Registry.new(), approved)
    assert activation.parent_id == parent.id
    assert activation.rollback_target_id == parent.id
    assert Registry.active(registry, {:project_instruction, :project, "project"}) == version

    assert {:ok, registry, rollback} = Registry.rollback(registry, activation, parent)
    assert rollback.action == :rollback
    assert Registry.active(registry, {:project_instruction, :project, "project"}) == parent
  end

  test "version digest changes with content but not map insertion order" do
    common = %{type: :configuration, layer: :tenant, scope: :tenant, tenant_id: "tenant"}

    assert {:ok, left} = Version.new(Map.put(common, :content, %{"a" => 1, "b" => 2}))
    assert {:ok, right} = Version.new(Map.put(common, :content, %{"b" => 2, "a" => 1}))
    assert left.digest == right.digest

    assert {:ok, changed} = Version.new(Map.put(common, :content, %{"a" => 2, "b" => 2}))
    refute left.digest == changed.digest
  end

  test "a delayed rollback cannot clobber a later approved activation" do
    attrs = %{type: :prompt, layer: :host, scope: :project, project_id: "project"}
    {:ok, base} = Version.new(Map.put(attrs, :content, "base"))
    {:ok, first} = Version.new(Map.merge(attrs, %{content: "first", parent_id: base.id}))
    {:ok, approved} = Proposal.approve(Proposal.new(first), %{"type" => "human", "id" => "owner"})
    {:ok, registry, activation} = Registry.activate(Registry.new(), approved)
    {:ok, second} = Version.new(Map.merge(attrs, %{content: "second", parent_id: first.id}))

    {:ok, approved} =
      Proposal.approve(Proposal.new(second), %{"type" => "human", "id" => "owner"})

    {:ok, registry, _} = Registry.activate(registry, approved)
    assert {:error, :invalid_rollback_target} = Registry.rollback(registry, activation, base)
    assert Registry.active(registry, Version.identity(second)) == second
  end

  test "rollback refuses a pointer that is no longer present" do
    attrs = %{type: :prompt, layer: :host, scope: :project, project_id: "project"}
    {:ok, base} = Version.new(Map.put(attrs, :content, "base"))
    {:ok, changed} = Version.new(Map.merge(attrs, %{content: "changed", parent_id: base.id}))

    {:ok, approved} =
      Proposal.approve(Proposal.new(changed), %{"type" => "human", "id" => "owner"})

    {:ok, registry, activation} = Registry.activate(Registry.new(), approved)

    assert {:error, :invalid_rollback_target} =
             Registry.rollback(%{registry | active: %{}}, activation, base)
  end
end
