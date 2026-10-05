defmodule Lemieux.Subagent.Replay do
  @moduledoc """
  Reconstructs durable subagent trees from ordinary `Lemieux.Store` entries.

  Registry and coordinator processes are live control planes, not persistence.
  This module groups spawn, child-result, and group-result facts by their stable
  ids so a host can rebuild a tree after process loss and distinguish an
  incomplete handoff from a failed child. It never guesses that a spawn intent
  succeeded: missing child/result records stay explicitly `:incomplete`.
  """

  alias Lemieux.Store
  alias Lemieux.Subagent.Group.Result, as: GroupResult
  alias Lemieux.Subagent.Result

  @doc "Replays every durable group beneath one parent transcript."
  @spec tree(store :: Store.t(), parent_id :: String.t()) :: {:ok, map()} | {:error, term()}
  def tree(store, parent_id) do
    with {:ok, entries} <- Store.read(store, parent_id) do
      groups =
        entries
        |> Enum.filter(&(&1.type == :subagent_spawn))
        |> Enum.group_by(& &1.payload["group_id"])
        |> Enum.map(fn {group_id, spawns} -> replay_group(store, entries, group_id, spawns) end)
        |> Enum.sort_by(& &1.first_seq)

      {:ok, %{root_session_id: parent_id, groups: groups}}
    end
  end

  @doc "Reads one persisted group result from a parent transcript."
  @spec group_result(store :: Store.t(), parent_id :: String.t(), group_id :: String.t()) ::
          {:ok, GroupResult.t()} | {:error, term()}
  def group_result(store, parent_id, group_id) do
    with {:ok, entries} <- Store.read(store, parent_id),
         %{payload: payload} <-
           Enum.find(entries, fn entry ->
             entry.type == :subagent_group_result and entry.payload["group_id"] == group_id
           end) || {:error, :not_found} do
      GroupResult.from_map(payload)
    end
  end

  @doc "Reads one persisted child result from a parent transcript."
  @spec child_result(store :: Store.t(), parent_id :: String.t(), child_id :: String.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def child_result(store, parent_id, child_id) do
    with {:ok, entries} <- Store.read(store, parent_id),
         %{payload: payload} <-
           Enum.find(entries, fn entry ->
             entry.type == :subagent_result and entry.payload["child_id"] == child_id
           end) || {:error, :not_found} do
      Result.from_map(payload)
    end
  end

  defp replay_group(store, parent_entries, group_id, spawns) do
    child_results =
      parent_entries
      |> Enum.filter(&(&1.type == :subagent_result and &1.payload["group_id"] == group_id))
      |> Map.new(&{&1.payload["child_id"], &1.payload})

    group_result =
      Enum.find(parent_entries, fn entry ->
        entry.type == :subagent_group_result and entry.payload["group_id"] == group_id
      end)

    children =
      Enum.map(spawns, fn spawn ->
        child_id = spawn.payload["child_id"]

        %{
          id: child_id,
          definition_id: spawn.payload["definition_id"],
          definition_digest: spawn.payload["definition_digest"],
          status: replay_status(store, child_id, child_results[child_id]),
          result: decode_child(child_results[child_id]),
          transcript_id: child_id,
          spawn_entry_id: spawn.id
        }
      end)

    %{
      id: group_id,
      first_seq: spawns |> List.first() |> Map.fetch!(:seq),
      status: replay_group_status(group_result, children),
      result: decode_group(group_result),
      children: children
    }
  end

  defp replay_status(_store, _child_id, payload) when is_map(payload) do
    case Result.from_map(payload) do
      {:ok, result} -> result.status
      {:error, _reason} -> :invalid_result
    end
  end

  defp replay_status(store, child_id, nil) do
    case Store.read(store, child_id) do
      {:ok, entries} -> if(terminal_child?(entries), do: :unreconciled, else: :incomplete)
      {:error, :not_found} -> :incomplete
      {:error, _reason} -> :unavailable
    end
  end

  defp terminal_child?(entries) do
    Enum.any?(entries, &(&1.type in [:assistant, :error, :cancelled, :subagent_result]))
  end

  defp replay_group_status(%{} = entry, _children) do
    case GroupResult.from_map(entry.payload) do
      {:ok, result} -> result.status
      {:error, _reason} -> :invalid_result
    end
  end

  defp replay_group_status(nil, children) do
    if Enum.all?(children, &(&1.status not in [:incomplete, :unreconciled])),
      do: :unreconciled,
      else: :incomplete
  end

  defp decode_child(nil), do: nil

  defp decode_child(payload),
    do:
      case(Result.from_map(payload),
        do: (
          {:ok, result} -> result
          _ -> nil
        )
      )

  defp decode_group(nil), do: nil

  defp decode_group(entry),
    do:
      case(GroupResult.from_map(entry.payload),
        do: (
          {:ok, result} -> result
          _ -> nil
        )
      )
end
