defmodule Lemieux.CLI.Learning.StudyBudget do
  @moduledoc false

  @spec research(requests :: pos_integer(), profile? :: boolean(), assets? :: boolean()) :: map()
  def research(requests, profile?, assets?) when requests in 8..200 do
    profile = if profile?, do: 8 * requests + 32, else: 0
    assets = if assets?, do: 8 * requests + 3, else: 0
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
        "requests" => max(192, profile + assets + (stages + 1) * requests + 2),
        "tokens" => tokens * stages + (stages + 1) * requests * 131_072 + 262_144,
        "time_ms" => profile_time + asset_time + (stages + 1) * task_time + 360_000,
        "cost_usd" => nil
      }
    }
  end
end
