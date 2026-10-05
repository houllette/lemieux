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
end
