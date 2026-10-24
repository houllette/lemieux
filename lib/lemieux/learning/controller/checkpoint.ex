defmodule Lemieux.Learning.Controller.Checkpoint do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Learning.Controller.Accounting

  @spec verify(recorded :: map(), job_id :: String.t(), maximum :: pos_integer()) ::
          :ok | {:error, term()}
  def verify(recorded, job_id, maximum) when is_map(recorded) do
    with true <- byte_size(JSON.encode!(recorded)) <= 4_194_304,
         :ok <- Contract.verify_digest(recorded, "sha256"),
         %{"schema_version" => version, "job_id" => ^job_id, "records" => records, "seen" => seen} <-
           recorded,
         true <- version in [1, 2],
         true <- is_map(records) and map_size(records) <= maximum + 1,
         true <- Enum.all?(records, &valid_record?/1),
         true <- reserves?(recorded, records, version),
         true <- is_list(seen) and length(seen) <= maximum and Enum.all?(seen, &digest?/1),
         true <- count?(recorded["initial_tokens"]) and count?(recorded["initial_requests"]),
         true <- is_integer(recorded["deadline_ms"]) and recorded["deadline_ms"] >= 0,
         true <- is_integer(recorded["stagnant"]) and recorded["stagnant"] in 0..4096,
         true <- is_nil(recorded["information"]) or digest?(recorded["information"]),
         true <-
           optional_reason?(recorded["stop"]) and optional_reason?(recorded["learning_stop"]) do
      :ok
    else
      _invalid -> {:error, :invalid_controller_checkpoint}
    end
  rescue
    _invalid -> {:error, :invalid_controller_checkpoint}
  end

  def verify(_invalid, _job_id, _maximum), do: {:error, :invalid_controller_checkpoint}

  defp reserves?(recorded, _records, 1), do: Map.get(recorded, "token_reserves", %{}) == %{}

  defp reserves?(recorded, records, 2) do
    reserves = recorded["token_reserves"]

    get_in(recorded, ["limits", "cost_mode"]) == "quota" and
      is_map(reserves) and map_size(reserves) > 0 and
      Accounting.valid_reserves?(reserves, records) and
      recorded["budget_tokens"] ==
        Accounting.budget_tokens(records, recorded["initial_tokens"], reserves)
  end

  defp valid_record?(
         {id,
          %{
            "id" => id,
            "decision" => "run",
            "role" => role,
            "status" => status,
            "reservation" => estimate,
            "usage" => usage
          } = record}
       ) do
    role in ~w(task proposer critic probe composition reflection confirmation) and
      status in ~w(reserved completed unknown interrupted) and facts?(estimate, true) and
      (is_nil(usage) or facts?(usage, false)) and timing?(record)
  end

  defp valid_record?(
         {id, %{"id" => id, "role" => role, "decision" => action, "reason" => reason}}
       ),
       do:
         is_binary(id) and byte_size(id) <= 128 and is_binary(role) and byte_size(role) <= 32 and
           action in ~w(skip stop consider select admit) and optional_reason?(reason)

  defp valid_record?(_invalid), do: false

  defp timing?(record),
    do:
      is_integer(record["issued_monotonic_ms"]) and
        Enum.all?(~w(timeout_ms deadline_ms), &(is_integer(record[&1]) and record[&1] >= 0))

  defp facts?(%{"tokens" => tokens, "time_ms" => time, "cost_usd" => cost} = facts, reservation?) do
    valid = count?(tokens) and count?(time) and dollars?(cost)
    valid and reservation_facts?(facts, reservation?)
  end

  defp facts?(_invalid, _reservation?), do: false
  defp dollars?(nil), do: true
  defp dollars?(value), do: is_number(value) and value >= 0
  defp reservation_facts?(_facts, false), do: true

  defp reservation_facts?(facts, true),
    do:
      is_integer(facts["tokens"]) and is_integer(facts["time_ms"]) and
        facts["time_ms"] > 0 and facts["requests"] in 1..2048

  defp count?(nil), do: true
  defp count?(value), do: is_integer(value) and value >= 0
  defp optional_reason?(nil), do: true
  defp optional_reason?(reason), do: is_binary(reason) and byte_size(reason) in 1..128
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
end
