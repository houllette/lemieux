defmodule Lemieux.Learning.Controller.Accounting do
  @moduledoc false
  alias Lemieux.Contract

  @doc "Budget-only upper accounting; measured usage remains in summarize/2."
  @spec budget_tokens(
          records :: map(),
          initial_tokens :: non_neg_integer() | nil,
          reserves :: map()
        ) :: non_neg_integer() | nil
  def budget_tokens(records, initial_tokens, reserves) do
    records
    |> Enum.filter(fn {_id, record} -> record["decision"] == "run" end)
    |> Enum.reduce(initial_tokens, fn {id, record}, total ->
      tokens = value(record, "tokens")
      amount = if is_integer(tokens), do: tokens, else: get_in(reserves, [id, "tokens"])
      add(total, amount)
    end)
  end

  @spec valid_reserves?(reserves :: term(), records :: map()) :: boolean()
  def valid_reserves?(reserves, records) when is_map(reserves) and map_size(reserves) <= 32,
    do: Enum.all?(reserves, &valid_reserve?(&1, records))

  def valid_reserves?(_reserves, _records), do: false

  defp valid_reserve?({id, receipt}, records) when is_map(receipt) do
    record = records[id]

    is_map(record) and unknown_task?(record) and identity?(receipt, id, record) and
      amount?(receipt, record) and approval?(receipt)
  end

  defp valid_reserve?(_reserve, _records), do: false

  defp unknown_task?(record),
    do:
      record["decision"] == "run" and record["role"] == "task" and
        record["status"] in ["unknown", "interrupted"] and is_nil(record["usage"])

  defp identity?(receipt, id, record),
    do:
      receipt["id"] == id and receipt["record_sha256"] == Contract.digest(record) and
        Contract.verify_digest(receipt, "sha256") == :ok

  defp amount?(receipt, record),
    do:
      is_integer(receipt["tokens"]) and receipt["tokens"] > 0 and
        receipt["tokens"] >= record["reservation"]["tokens"]

  defp approval?(receipt),
    do:
      is_binary(receipt["approval"]) and byte_size(receipt["approval"]) in 1..2048 and
        is_integer(receipt["approved_at_ms"]) and receipt["approved_at_ms"] >= 0 and
        is_binary(receipt["prior_checkpoint_sha256"]) and
        Regex.match?(~r/\A[a-f0-9]{64}\z/, receipt["prior_checkpoint_sha256"])

  @spec summarize(records :: map(), initial_tokens :: non_neg_integer() | nil) :: map()
  def summarize(records, initial_tokens) do
    runs = records |> Map.values() |> Enum.filter(&(&1["decision"] == "run"))
    learning = Enum.reject(runs, &(&1["role"] == "task"))
    cost_micros = Enum.reduce(learning, 0, &add(micros(value(&1, "cost_usd")), &2))

    %{
      "requests" => requests(runs),
      "tokens" => add(initial_tokens, sum(runs, "tokens")),
      "learning_requests" => requests(learning),
      "learning_tokens" => sum(learning, "tokens"),
      "learning_time_ms" => sum(learning, "time_ms"),
      "learning_cost_micros" => cost_micros,
      "learning_cost_usd" => if(is_integer(cost_micros), do: cost_micros / 1_000_000)
    }
  end

  defp requests(records),
    do: Enum.sum(Enum.map(records, &Map.get(&1["reservation"], "requests", 1)))

  defp sum(records, field), do: Enum.reduce(records, 0, &add(value(&1, field), &2))

  defp value(%{"status" => "reserved", "reservation" => reservation}, field),
    do: reservation[field]

  defp value(%{"usage" => usage}, field) when is_map(usage), do: usage[field]
  defp value(_unknown, _field), do: nil
  defp add(a, b) when is_number(a) and is_number(b), do: a + b
  defp add(_a, _b), do: nil

  @spec capacity(state :: map(), role :: String.t(), estimate :: map(), now :: integer()) ::
          :ok | {:stop | :skip, String.t()}
  def capacity(state, role, estimate, now) do
    accounting = summarize(state.records, state.initial_tokens)

    budget =
      Map.put(
        accounting,
        "tokens",
        budget_tokens(state.records, state.initial_tokens, state.token_reserves)
      )

    with :ok <- runtime_capacity(state, budget, estimate, now),
         do: refinement_capacity(state, role, accounting, estimate)
  end

  defp runtime_capacity(state, accounting, estimate, now) do
    cond do
      not is_nil(state.stop) ->
        {:stop, state.stop}

      state.persist_failed ->
        {:stop, "persistence_unavailable"}

      map_size(state.records) >= state.max_records ->
        {:stop, "decision_limit"}

      now >= state.mono_deadline ->
        {:stop, "deadline_exhausted"}

      is_nil(accounting["tokens"]) ->
        {:stop, "usage_unknown"}

      accounting["tokens"] + estimate["tokens"] > state.max_tokens ->
        {:skip, "token_allowance_exhausted"}

      true ->
        :ok
    end
  end

  defp refinement_capacity(state, role, accounting, estimate) do
    cond do
      state.cost_mode == :metered and is_nil(estimate["cost_usd"]) ->
        {:skip, "price_unknown"}

      role == "task" ->
        :ok

      not is_nil(state.learning_stop) ->
        {:stop, state.learning_stop}

      not learning_capacity?(state.learning, accounting, estimate) ->
        {:skip, "learning_allowance_exhausted"}

      true ->
        :ok
    end
  end

  defp learning_capacity?(limits, used, estimate) do
    enough?(limits["max_requests"], used["learning_requests"], estimate["requests"]) and
      enough?(limits["max_tokens"], used["learning_tokens"], estimate["tokens"]) and
      enough?(limits["max_time_ms"], used["learning_time_ms"], estimate["time_ms"]) and
      dollars?(limits["max_cost_usd"], used["learning_cost_micros"], estimate["cost_usd"])
  end

  defp enough?(cap, used, amount) when is_integer(used) and is_integer(amount),
    do: used + amount <= cap

  defp enough?(_cap, _used, _amount), do: false
  defp dollars?(nil, _used, _amount), do: true

  defp dollars?(cap, used, amount) when is_number(used) and is_number(amount),
    do: used + micros(amount) <= micros(cap)

  defp dollars?(_cap, _used, _amount), do: false
  defp micros(value) when is_number(value) and value >= 0, do: ceil(value * 1_000_000)
  defp micros(_unknown), do: nil
end
