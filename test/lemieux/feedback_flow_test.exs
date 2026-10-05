defmodule Lemieux.FeedbackFlowTest do
  use ExUnit.Case, async: true

  alias Lemieux.Asset.Registry
  alias Lemieux.Feedback
  alias Lemieux.Feedback.Flow

  @moduletag :tmp_dir

  test "turns formatter feedback into a failing case and approved reversible asset without a model call",
       context do
    source = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "code.ex"), "defmodule Code,do: nil\n")

    {:ok, feedback} =
      Feedback.new("run the formatter before finishing", provenance(),
        verifiability: %{"class" => "mechanical", "claim" => "formatter ran"},
        durability: :standing_rule
      )

    assert {:ok, flow} =
             Flow.prepare(
               feedback,
               [
                 source_dir: source,
                 output_dir: Path.join(context.tmp_dir, "drafts"),
                 prompt: "Make the change and format it.",
                 verifier: ["sh", "-c", "test -f formatter-ran"]
               ],
               %{
                 type: :project_instruction,
                 layer: :project,
                 scope: :project,
                 project_id: "project",
                 content: "Run the formatter before finishing."
               }
             )

    assert flow.case_draft.status == :draft
    assert flow.proposal.status == :proposed
    assert flow.proposal.version.motivating_feedback_ids == [feedback.id]

    actor = %{"type" => "human", "id" => "owner"}
    assert {:ok, activated, registry, _activation} = Flow.approve(flow, actor, Registry.new())
    assert activated.proposal.status == :approved
    assert Registry.active(registry, {:project_instruction, :project, "project"})
  end

  defp provenance do
    %{
      "host" => "standalone",
      "tenant_id" => "local",
      "project_id" => "project",
      "session_id" => "session",
      "entry_id" => "entry"
    }
  end
end
