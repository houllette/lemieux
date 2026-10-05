defmodule Lemieux.Experiment.State do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Pure, auditable lifecycle transitions for feedback-driven experiments.

  The struct is a projection, not the durable authority. Hosts persist each
  transition with compare-and-set semantics and may reconstruct this value
  after a coordinator crash. Paid attempts are never supervisor-restarted as
  a consequence of this module; a retry is a new idempotent attempt record.
  """

  @terminal ~w(non_experimental rejected inconclusive aborted rolled_back closed)a

  @type status ::
          :captured
          | :triaged
          | :needs_clarification
          | :non_experimental
          | :case_draft
          | :case_approved
          | :planned
          | :approved
          | :running
          | :evaluating
          | :decision_pending
          | :promoted
          | :monitoring
          | :rejected
          | :inconclusive
          | :aborted
          | :rolled_back
          | :closed
  @type transition :: %{from: status(), to: status(), facts: map(), at: DateTime.t()}
  @type t :: %__MODULE__{experiment_id: String.t(), status: status(), history: [transition()]}

  @enforce_keys [:experiment_id]
  defstruct [:experiment_id, status: :captured, history: []]

  @doc "Creates the initial captured lifecycle projection."
  @spec new(experiment_id :: String.t()) :: t()
  def new(experiment_id) when is_binary(experiment_id) and experiment_id != "" do
    %__MODULE__{experiment_id: experiment_id}
  end

  @doc "Applies one allowed transition after checking its host-supplied facts."
  @spec transition(state :: t(), destination :: status(), facts :: map()) ::
          {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: status}, destination, _facts)
      when status in @terminal,
      do: {:error, {:terminal_state, status, destination}}

  def transition(%__MODULE__{} = state, destination, facts) when is_map(facts) do
    with {:ok, gates} <- gates(state.status, destination),
         :ok <- check_special(state.status, destination, facts),
         :ok <- require_gates(gates, facts) do
      record = %{from: state.status, to: destination, facts: facts, at: DateTime.utc_now()}
      {:ok, %{state | status: destination, history: state.history ++ [record]}}
    end
  end

  defp gates(:captured, :triaged), do: {:ok, ~w(anchor_resolved authorized raw_preserved)a}
  defp gates(:captured, :non_experimental), do: {:ok, [:reason]}
  defp gates(:triaged, :needs_clarification), do: {:ok, [:question_count]}
  defp gates(:needs_clarification, :triaged), do: {:ok, [:question_count]}
  defp gates(:triaged, :non_experimental), do: {:ok, [:reason]}
  defp gates(:triaged, :case_draft), do: {:ok, [:verifiability]}
  defp gates(:case_draft, :case_approved), do: {:ok, ~w(case_digest regression_reproduced)a}
  defp gates(:case_draft, :closed), do: {:ok, [:reason]}
  defp gates(:case_approved, :planned), do: {:ok, [:plan_valid]}
  defp gates(:planned, :approved), do: {:ok, ~w(policy_approved budget_reserved)a}
  defp gates(:planned, :rejected), do: {:ok, [:reason]}
  defp gates(:approved, :running), do: {:ok, ~w(idempotency_key workspaces_acquired)a}

  defp gates(:running, :evaluating),
    do: {:ok, ~w(attempts_terminal observations_complete attestations_valid)a}

  defp gates(:running, :aborted), do: {:ok, [:reason]}

  defp gates(:evaluating, :decision_pending),
    do: {:ok, ~w(evaluator_signed splits_separated uncertainty_reported)a}

  defp gates(:evaluating, :rejected), do: {:ok, [:reason]}
  defp gates(:evaluating, :inconclusive), do: {:ok, [:reason]}

  defp gates(:decision_pending, :promoted),
    do: {:ok, ~w(asset_eligible gates_passed rollback_ready monitoring_ready)a}

  defp gates(:decision_pending, :rejected), do: {:ok, [:reason]}
  defp gates(:decision_pending, :inconclusive), do: {:ok, [:reason]}
  defp gates(:promoted, :monitoring), do: {:ok, [:monitoring_installed]}
  defp gates(:monitoring, :rolled_back), do: {:ok, ~w(incident prior_restored)a}
  defp gates(:monitoring, :closed), do: {:ok, [:stable]}

  defp gates(from, to), do: {:error, {:invalid_transition, from, to}}

  defp check_special(from, to, %{question_count: count})
       when {from, to} in [
              {:triaged, :needs_clarification},
              {:needs_clarification, :triaged}
            ] and is_integer(count) and count > 3,
       do: {:error, :too_many_questions}

  defp check_special(:triaged, :case_draft, %{verifiability: class})
       when class not in [:mechanical, :environmental],
       do: {:error, {:not_experiment_eligible, class}}

  defp check_special(_from, _to, _facts), do: :ok

  defp require_gates(gates, facts) do
    Enum.reduce_while(gates, :ok, fn gate, :ok ->
      case Map.fetch(facts, gate) do
        {:ok, value} when value not in [false, nil, "", []] -> {:cont, :ok}
        _missing -> {:halt, {:error, {:gate_failed, gate}}}
      end
    end)
  end
end
