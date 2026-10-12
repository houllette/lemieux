defmodule Lemieux.Jobs.Ledger do
  @moduledoc false
  alias Lemieux.JobBudget
  alias Lemieux.Jobs.Journal

  @spec start(
          journal :: Journal.t(),
          job :: map(),
          execution :: Lemieux.Execution.t(),
          runtime :: atom()
        ) ::
          {:ok, pid()} | {:error, term()}
  def start(journal, job, execution, runtime) do
    key = "budget-" <> job["id"]

    recorded =
      case Journal.read(journal, key) do
        {:ok, record} -> record.value
        {:error, :not_found} -> %{}
        {:error, reason} -> raise "could not read job budget: #{inspect(reason)}"
      end

    recorded = Map.put(recorded, "epoch", job["epoch"])

    revision =
      case Journal.read(journal, key) do
        {:ok, record} -> record.revision
        {:error, :not_found} -> 0
      end

    {:ok, _record} = Journal.write(journal, key, revision, recorded)
    manager = self()

    persist = fn snapshot -> persist(journal, key, job["epoch"], manager, snapshot) end

    limits =
      for {key, value} <- job["intent"]["limits"],
          do: {limit_key(key), value}

    options =
      limits ++ [recorded: recorded, persist: persist, execution: execution, owner: manager]

    DynamicSupervisor.start_child(
      Lemieux.Supervisor.background_supervisor(runtime),
      {JobBudget, options}
    )
  end

  @spec snapshot(journal :: Journal.t(), id :: String.t()) :: map() | nil
  def snapshot(journal, id) do
    case Journal.read(journal, "budget-" <> id) do
      {:ok, record} -> Map.delete(record.value, "epoch")
      {:error, :not_found} -> nil
      {:error, reason} -> raise "could not read job budget: #{inspect(reason)}"
    end
  end

  defp persist(journal, key, epoch, manager, snapshot) do
    if not Process.alive?(manager), do: exit(:job_host_down)
    {:ok, _record} = Journal.update(journal, key, &persisted(&1, epoch, snapshot))
    :ok
  end

  defp persisted(current, epoch, snapshot) do
    if current["epoch"] != epoch, do: exit(:stale_job_budget)
    snapshot |> Lemieux.Contract.json() |> Map.put("epoch", epoch)
  end

  defp limit_key("max_requests"), do: :max_requests
  defp limit_key("max_cost_usd"), do: :max_cost_usd
end
