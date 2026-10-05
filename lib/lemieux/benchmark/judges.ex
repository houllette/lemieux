if Code.ensure_loaded?(Tribunal.Judge) do
  defmodule Lemieux.Benchmark.Judges.CommitQuality do
    @moduledoc false
    @behaviour Tribunal.Judge

    @impl Tribunal.Judge
    def name, do: :commit_quality

    @impl Tribunal.Judge
    def prompt(test_case, _opts) do
      """
      Evaluate the quality of this coding-task commit message. It should be
      concise, specific, imperative, and supported by the recorded change.

      Task:
      #{test_case.input}

      Recorded change:
      #{Enum.join(List.wrap(test_case.context), "\n")}

      Commit message:
      #{test_case.actual_output}
      """
    end
  end

  defmodule Lemieux.Benchmark.Judges.ExplanationFaithfulness do
    @moduledoc false
    @behaviour Tribunal.Judge

    @impl Tribunal.Judge
    def name, do: :explanation_faithfulness

    @impl Tribunal.Judge
    def prompt(test_case, _opts) do
      """
      Evaluate whether the final explanation is faithful to the recorded patch,
      changed paths, and test outcomes. Fail invented changes or unrun tests.

      Task:
      #{test_case.input}

      Recorded evidence:
      #{Enum.join(List.wrap(test_case.context), "\n")}

      Final explanation:
      #{test_case.actual_output}
      """
    end
  end
end
