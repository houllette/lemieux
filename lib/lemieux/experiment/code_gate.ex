defmodule Lemieux.Experiment.CodeGate do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Fail-closed evidence gate for harness-code candidates.

  Passing this gate means a candidate is reviewable, not deployed. Generated
  Lemieux source must still enter ordinary human-owned release machinery; this
  module deliberately has no callback capable of activating a release.
  """

  @required ~w(clean_worktree microvm pinned_base precommit safety compatibility held_out)

  @doc "The evidence categories a code candidate must supply."
  @spec required_evidence() :: [String.t()]
  def required_evidence, do: @required

  @doc "Validates complete, passing, digest-bearing release evidence."
  @spec evaluate(evidence :: map()) :: {:ok, map()} | {:error, term()}
  def evaluate(evidence) when is_map(evidence) do
    missing = Enum.reject(@required, &passing?(Map.get(evidence, &1)))

    if missing == [] do
      {:ok,
       %{
         passed: true,
         production_active: false,
         next_gate: :human_release_approval,
         evidence: evidence
       }}
    else
      {:error, {:missing_evidence, missing}}
    end
  end

  defp passing?(%{"passed" => true, "digest" => digest}) when is_binary(digest) and digest != "",
    do: true

  defp passing?(_evidence), do: false
end
