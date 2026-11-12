defmodule Lemieux.Subagent.Error do
  @moduledoc """
  Readable admission failures with the original diagnostic alongside them.

  The text is a projection, never the accounting record: subtract integer
  micros before rounding for display. A tree cap is local policy, not an
  account balance. Unknown failures retain their evidence for inspection.
  """

  alias Lemieux.Contract
  alias Lemieux.Tool.Result

  @doc "Builds a transcript-safe failure without discarding its original reason."
  @spec result(reason :: term()) :: Result.t()
  def result(reason) do
    Result.new(message(Contract.json(reason)),
      structured_content: %{
        "subagent_error" => Contract.json(reason),
        "original" => inspect(reason, limit: :infinity, printable_limit: :infinity)
      }
    )
  end

  @doc "Explains a JSON diagnostic; missing amounts remain explicitly unknown."
  @spec message(reason :: term()) :: String.t()
  def message(%{"reason" => "tree_budget"} = reason) do
    amounts =
      case Map.get(reason, "micros") do
        amounts when is_map(amounts) -> amounts
        _unknown -> %{}
      end

    cap = amounts["cap"]
    spent = amounts["spent"]
    reserved = amounts["reserved"]

    remaining =
      if Enum.all?([cap, spent, reserved], &(is_integer(&1) and &1 >= 0)),
        do: max(cap - spent - reserved, 0)

    "Subagent launch exceeds this run's tree budget: requested #{dollars(amounts["requested"])}, " <>
      "available #{dollars(remaining)} (cap #{dollars(cap)}, spent #{dollars(spent)}, " <>
      "reserved #{dollars(reserved)}). Request a smaller subagent budget, or explicitly " <>
      "adjust the configured tree limit. This is not the provider account balance."
  end

  def message(["root_limit", limit]) when is_integer(limit),
    do:
      "Subagent launch would exceed the limit of #{limit} active children. Wait for existing children to finish or request fewer children."

  def message(["root_request_budget_exhausted", _amounts]),
    do:
      "Subagent launch exceeds this run's request budget. Request fewer model calls or explicitly adjust the configured tree limit."

  def message("duplicate_work_in_group"),
    do: "Subagent launch contains duplicate work. Give each child a distinct investigation."

  def message(text) when is_binary(text) and text != "" do
    if String.contains?(text, " "), do: text, else: message(%{})
  end

  def message(_unknown),
    do:
      "Subagent launch failed. Inspect the saved tool result for the full diagnostic before retrying."

  defp dollars(micros) when is_integer(micros) and micros >= 0,
    do: "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 2)

  defp dollars(_unknown), do: "unknown"
end
