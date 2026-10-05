defmodule LemieuxBuilderBench.RefinementCases do
  @moduledoc false
  @sources ~w(lib/lemieux/extension/profile.ex lib/lemieux/learning/extension/workbench.ex lib/lemieux/learning/extension/model_search.ex lib/lemieux/cli/extension_experience.ex lib/lemieux/learning/builder/scaffold.ex)

  @spec prepare(root :: Path.t(), repository :: Path.t()) :: [String.t()]
  def prepare(root, repository) do
    case File.mkdir(root) do
      :ok ->
        ids = create(root, repository)
        {:ok, _} = Lemieux.Learning.Extension.Tree.seal(root, "inputs.json", %{"case_ids" => ids})
        ids

      {:error, :eexist} ->
        {:ok, receipt} = Lemieux.Learning.Extension.Tree.read(Path.join(root, "inputs.json"))
        {:ok, verified} = Lemieux.Learning.Extension.Tree.verify(root, "inputs.json", receipt["sha256"])
        verified["case_ids"]
    end
  end

  @spec create(root :: Path.t(), repository :: Path.t()) :: [String.t()]
  def create(root, repository) do
    for id <- ~w(audit_clean audit_bound) do
      cwd = Path.join(root, id)

      for file <- @sources do
        target = Path.join(cwd, file)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(Path.join(repository, file), target)
      end

      if id == "audit_bound" do
        target = Path.join(cwd, "lib/lemieux/learning/extension/workbench.ex")
        original = File.read!(target)
        true = String.contains?(original, "min(existing, maximum)")

        File.write!(
          target,
          String.replace(original, "min(existing, maximum)", "max(existing, maximum)")
        )
      end

      File.write!(Path.join(cwd, "brief.txt"), """
      Audit these source copies of Lemieux's extension workflow for concrete quota
      and model-selection defects. Sources may be correct; do not invent a bug.
      Read the relevant sources. Do not change them, scaffold, run Mix/Elixir,
      launch model processes, or read outside this workspace.
      Write review.json: {"findings":[{"file":"relative source path","quote":"exact
      defective source expression","description":"why it violates a contract"}]}.
      Use an empty findings array if there is no demonstrated defect. Then write
      BUILDING.md with a concise account of evidence and remaining validation.
      Validation-only tools intentionally do not mutate search files. Finish once
      those two artifacts are saved. A source review is not live confirmation.
      """)
    end

    for id <- ~w(repair_profile continue_work) do
      cwd = Path.join(root, id)
      File.mkdir_p!(Path.join(cwd, "priv"))
      File.mkdir_p!(Path.join(cwd, "lib"))

      File.write!(
        Path.join(cwd, "lib/agent.ex"),
        "# Developer-owned source: preserve byte for byte.\n"
      )

      File.write!(Path.join(cwd, "README.md"), "Developer-owned README. Do not replace.\n")

      File.write!(
        Path.join(cwd, "BUILDING.md"),
        "# Decisions\nPreserve line citations in every summary.\n"
      )

      profile = %{
        "execution" => "live",
        "model" => "zai_coding_plan:glm-4.7",
        "tools" => ["read"],
        "options" => %{
          "system" => "Summarize reports with citations.",
          "max_turns" => 4,
          "max_tokens" => 512,
          "max_cost_usd" => nil,
          "usage_mode" => "quota",
          "max_requests" => 2,
          "reasoning_effort" => if(id == "repair_profile", do: "high", else: "default"),
          "temperature" => 0.2
        }
      }

      File.write!(Path.join(cwd, "priv/profile.json"), JSON.encode!(profile))

      brief =
        if id == "repair_profile" do
          """
          The last configuration attempt failed: effort_not_available for
          zai_coding_plan:glm-4.7 high. Repair priv/profile.json to use default effort.
          Preserve every other profile setting, existing source and README, and the
          existing BUILDING.md decision. Record the repair and pending validation in
          BUILDING.md. Do not run benchmarks, launch model processes, or scaffold.
          Write outcome.json with {"benchmarked":false,"qualification":"unassessed"}.
          """
        else
          """
          Continue this interrupted extension project. Preserve priv/profile.json,
          existing source, README and BUILDING.md decision. The developer's explicit
          comparison shortlist is zai_coding_plan:glm-5.3 at default and low effort,
          and zai_coding_plan:glm-4.7 at default effort. Validate the selection with
          extension_workflow select_models, then write that exact shortlist to
          bench/models.json. Validation does not write files for you. Record the
          remaining comparison/confirmation work in BUILDING.md. Do not scaffold,
          run benchmarks, launch model processes, or infer a winner. Write
          outcome.json with {"benchmarked":false,"qualification":"unassessed"}.
          """
        end

      File.write!(
        Path.join(cwd, "brief.txt"),
        brief <> "\nUse only this workspace; quota usage for this authoring task is authorized.\n"
      )
    end

    ~w(audit_clean audit_bound repair_profile continue_work)
  end
end
