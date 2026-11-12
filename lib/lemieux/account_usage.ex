defmodule Lemieux.AccountUsage do
  @moduledoc """
  Provider-reported account usage, distinct from session token accounting.

  Hosts supply a read-only reporting callback to their conversation dispatcher.
  The library formats its bounded projection and caches that projection only;
  it owns no reporting endpoint, credentials or background polling.
  """

  @doc "Whether a report is fresh enough to reuse without another request."
  @spec fresh?(report :: map() | nil, now :: integer()) :: boolean()
  def fresh?(%{fetched_at: at}, now) when is_integer(at), do: (now - at) in 0..59
  def fresh?(_report, _now), do: false

  @doc "Keeps a previously successful provider result explicitly stale on refresh failure."
  @spec merge(report :: map(), previous :: map() | nil) :: map()
  def merge(report, %{accounts: old}) do
    accounts =
      Enum.map(report.accounts, fn account ->
        cached =
          Enum.find(
            old,
            &(&1.provider == account.provider and &1.status == :ok and
                is_binary(Map.get(account, :scope_key)) and
                Map.get(&1, :scope_key) == account.scope_key)
          )

        if account.status == :error and cached,
          do: Map.merge(cached, %{stale?: true, message: account.message}),
          else: account
      end)

    %{report | accounts: accounts}
  end

  def merge(report, _previous), do: report

  @doc "Formats only reported fields; an absent amount or reset remains unknown."
  @spec format(report :: map(), opts :: keyword()) :: String.t()
  def format(report, opts \\ []) do
    stamp = timestamp(report.fetched_at)
    cached = if Keyword.get(opts, :cached, false), do: " · cached", else: ""

    heading =
      "Provider account usage · fetched #{stamp}#{cached}\n" <>
        "Account reports differ from /context session usage and configured run budgets. /usage refresh fetches again."

    rows = Enum.map_join(report.accounts, "\n", &account/1)

    heading <>
      "\n" <> if(rows == "", do: "No provider accounts are configured for reporting.", else: rows)
  end

  defp account(%{provider: provider, status: :ok} = account) do
    stale = if Map.get(account, :stale?, false), do: " · STALE (refresh failed)", else: ""

    "#{provider} · #{account.scope}#{stale} · fetched #{timestamp(account.fetched_at)}\n" <>
      Enum.map_join(account.windows, "\n", &window/1) <>
      case Map.get(account, :message) do
        nil -> ""
        message -> "\n  " <> message
      end
  end

  defp account(account), do: "#{account.provider} · #{account.message}"

  defp window(window) do
    "  #{window.label}: used #{amount(window.used, window.unit)} · " <>
      "remaining #{amount(window.remaining, window.unit)} · " <>
      "window #{timestamp(window.start_at)} to #{timestamp(window.end_at)} · reset #{timestamp(window.reset_at)}"
  end

  defp amount(value, "percent") when is_number(value), do: "#{value}%"

  defp amount(value, unit) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 2) <> " " <> unit

  defp amount(_unknown, _unit), do: "unknown"

  defp timestamp(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, at} -> DateTime.to_iso8601(at)
      _invalid -> "unknown"
    end
  end

  defp timestamp(_unknown), do: "unknown"
end
