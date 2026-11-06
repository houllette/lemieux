defmodule Lemieux.CLI.Learning.StudyBudget do
  @moduledoc false
  alias Lemieux.CLI.Learning.AssetPolicy

  @spec research(requests :: pos_integer(), profile? :: boolean(), assets? :: boolean()) :: map()
  @spec research(
          requests :: pos_integer(),
          profile? :: boolean(),
          assets? :: boolean(),
          opts :: keyword()
        ) :: map()
  def research(requests, profile?, assets?, opts \\ []) when requests in 8..200 do
    profile = if profile?, do: 8 * requests + 32, else: 0
    selective? = assets? and selective?(opts[:asset_protocol])
    assets = asset_requests(requests, assets?, opts[:asset_protocol])
    stages = Enum.count([profile?, assets?], & &1)
    tokens = max(4_500_000, 8 * requests * 65_536)
    profile_time = if profile?, do: max(1_500_000, profile * 10_000), else: 0
    asset_time = if assets?, do: max(1_500_000, assets * 10_000), else: 0
    task_time = max(480_000, requests * 10_000)

    %{
      profile_requests: profile,
      asset_requests: assets,
      experiment_tokens: tokens,
      profile_time_ms: profile_time,
      asset_time_ms: asset_time,
      task_time_ms: task_time,
      allowance: %{
        "requests" =>
          max(if(selective?, do: 0, else: 192), profile + assets + (stages + 1) * requests + 2),
        "tokens" => tokens * stages + (stages + 1) * requests * 131_072 + 262_144,
        "time_ms" => profile_time + asset_time + (stages + 1) * task_time + 360_000,
        "cost_usd" => nil
      }
    }
  end

  defp selective?(%{"id" => "reviewed_assets/v5", "selection_policy" => policy}),
    do: AssetPolicy.valid?(policy)

  defp selective?(_protocol), do: false

  defp asset_requests(_requests, false, _protocol), do: 0

  defp asset_requests(
         requests,
         true,
         %{"id" => "reviewed_assets/v5", "maximum_candidates" => count} = protocol
       )
       when count in 1..2 do
    if selective?(protocol),
      do: AssetPolicy.probe_count(count) * requests + 2 + count,
      else: raise(ArgumentError, "unrecognized selective asset policy")
  end

  defp asset_requests(requests, true, _legacy), do: 8 * requests + 4
end
