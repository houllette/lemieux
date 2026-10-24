defmodule Lemieux.CLI.Learning.StudyRegistration do
  @moduledoc false
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.Contract
  alias Lemieux.Learning.Controller.Accounting
  alias Lemieux.Learning.Controller.Checkpoint

  @maximum 8_388_608

  @spec load(directory :: Path.t(), limits :: keyword()) ::
          {:ok, map() | nil, function()} | {:error, term()}
  def load(directory, limits) do
    path = Path.join(directory, "authorization.json")
    current = Contract.json(Map.new(limits))

    case {File.exists?(path), File.exists?(Path.join(directory, "controller.json"))} do
      {false, false} ->
        with :ok <- write(path, %{"limits" => current}),
             do: {:ok, nil, &checkpoint_write(Path.join(directory, "controller.json"), &1, &1)}

      {true, true} ->
        restore(directory, path, current)

      _partial ->
        {:error, :incomplete_study_allowance}
    end
  rescue
    _invalid in [
      ArgumentError,
      ArithmeticError,
      BadMapError,
      FunctionClauseError,
      KeyError,
      Protocol.UndefinedError
    ] ->
      {:error, :invalid_study_registration}
  end

  defp restore(directory, path, current) do
    with {:ok, registration} <- read(path),
         {:ok, checkpoint} <- registered(directory, registration, current) do
      {:ok, checkpoint, persister(directory, path, registration)}
    end
  end

  defp persister(_directory, path, %{"schema_version" => 2} = registration),
    do: &checkpoint_write(path, Map.put(registration, "checkpoint", &1), &1)

  defp persister(directory, _path, _registration),
    do: &checkpoint_write(Path.join(directory, "controller.json"), &1, &1)

  @spec amend(
          directory :: Path.t(),
          previous :: keyword(),
          limits :: keyword(),
          approval :: String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  def amend(directory, previous, limits, approval) do
    path = Path.join(directory, "authorization.json")
    prior = Contract.json(Map.new(previous))
    current = Contract.json(Map.new(limits))

    with true <- is_binary(approval) and byte_size(approval) in 1..2048,
         true <- Enum.all?(current, fn {key, value} -> value >= prior[key] end),
         false <- current == prior,
         {:ok, registration} <- read(path),
         {:ok, checkpoint} <- registered(directory, registration, prior) do
      original =
        Map.get(registration, "original", %{
          "authorization" => registration,
          "checkpoint_sha256" => checkpoint["sha256"],
          "deadline_ms" => checkpoint["deadline_ms"]
        })

      amendments = Map.get(registration, "amendments", [])
      deadline = checkpoint["deadline_ms"] + current["max_time_ms"] - prior["max_time_ms"]

      receipt =
        Journal.seal(%{
          "approval" => approval,
          "approved_at_ms" => System.system_time(:millisecond),
          "prior_limits" => prior,
          "limits" => current,
          "prior_checkpoint_sha256" => checkpoint["sha256"],
          "previous_sha256" =>
            if(amendments == [],
              do: original["authorization"]["sha256"],
              else: List.last(amendments)["sha256"]
            ),
          "deadline_ms" => deadline
        })

      checkpoint =
        checkpoint
        |> Map.put("deadline_ms", deadline)
        |> put_in(["limits", "max_tokens"], current["max_tokens"])
        |> put_in(["limits", "learning"], Map.put(current, "max_cost_usd", nil))
        |> put_in(["job_budget", "max_requests"], current["max_requests"])
        |> Journal.seal()

      # This single atomic replacement commits both authority and accounting.
      # V1 readers require top-level `limits`, so they refuse this envelope.
      # controller.json remains the immutable pre-amendment checkpoint.
      envelope = %{
        "schema_version" => 2,
        "original" => original,
        "amendments" => amendments ++ [receipt],
        "current_limits" => current,
        "checkpoint" => checkpoint
      }

      with true <- length(amendments) < 32,
           :ok <- checkpoint_write(path, envelope, checkpoint),
           do: {:ok, receipt}
    else
      _invalid -> {:error, :invalid_study_amendment}
    end
  rescue
    _invalid in [
      ArgumentError,
      ArithmeticError,
      BadMapError,
      FunctionClauseError,
      KeyError,
      Protocol.UndefinedError
    ] ->
      {:error, :invalid_study_amendment}
  end

  defp registered(directory, %{"limits" => current} = registration, current)
       when map_size(registration) == 2 do
    with {:ok, checkpoint} <- read(Path.join(directory, "controller.json")),
         :ok <- verify(checkpoint, directory, current),
         do: {:ok, checkpoint}
  end

  defp registered(
         directory,
         %{"schema_version" => 2, "current_limits" => current} = registration,
         current
       ) do
    original = registration["original"]
    checkpoint = registration["checkpoint"]

    with {:ok, archived} <- read(Path.join(directory, "controller.json")),
         true <- archived["sha256"] == original["checkpoint_sha256"],
         :ok <- Contract.verify_digest(original["authorization"], "sha256"),
         {:ok, ^current, deadline} <- amendments(registration),
         true <- checkpoint["deadline_ms"] <= deadline,
         :ok <- verify(checkpoint, directory, current) do
      {:ok, checkpoint}
    else
      _invalid -> {:error, :invalid_study_registration}
    end
  end

  defp registered(_directory, _registration, _current),
    do: {:error, :study_allowance_changed_or_invalid}

  @spec reserve_unknown(
          directory :: Path.t(),
          limits :: keyword(),
          id :: String.t(),
          tokens :: pos_integer(),
          approval :: String.t()
        ) :: {:ok, map()} | {:error, term()}
  def reserve_unknown(directory, limits, id, tokens, approval) do
    path = Path.join(directory, "authorization.json")
    current = Contract.json(Map.new(limits))

    with true <- is_binary(approval) and byte_size(approval) in 1..2048,
         true <- is_integer(tokens) and tokens > 0 and tokens <= current["max_tokens"],
         {:ok, registration} <- read(path),
         {:ok, checkpoint} <- registered(directory, registration, current),
         true <- is_nil(checkpoint["stop"]),
         record when is_map(record) <- checkpoint["records"][id],
         reserves = Map.get(checkpoint, "token_reserves", %{}),
         false <- Map.has_key?(reserves, id) do
      receipt =
        Journal.seal(%{
          "id" => id,
          "record_sha256" => Contract.digest(record),
          "tokens" => tokens,
          "approval" => approval,
          "approved_at_ms" => System.system_time(:millisecond),
          "prior_checkpoint_sha256" => checkpoint["sha256"]
        })

      reserves = Map.put(reserves, id, receipt)

      original =
        Map.get(registration, "original", %{
          "authorization" => registration,
          "checkpoint_sha256" => checkpoint["sha256"],
          "deadline_ms" => checkpoint["deadline_ms"]
        })

      checkpoint =
        checkpoint
        |> Map.put("schema_version", 2)
        |> Map.put("token_reserves", reserves)
        |> Map.put(
          "budget_tokens",
          Accounting.budget_tokens(checkpoint["records"], checkpoint["initial_tokens"], reserves)
        )
        |> Journal.seal()

      envelope = %{
        "schema_version" => 2,
        "original" => original,
        "amendments" => Map.get(registration, "amendments", []),
        "current_limits" => current,
        "checkpoint" => checkpoint
      }

      with true <- Accounting.valid_reserves?(reserves, checkpoint["records"]),
           :ok <- verify(checkpoint, directory, current),
           :ok <- checkpoint_write(path, envelope, checkpoint) do
        {:ok, receipt}
      else
        _invalid -> {:error, :invalid_usage_reserve}
      end
    else
      _invalid -> {:error, :invalid_usage_reserve}
    end
  rescue
    _invalid in [
      ArgumentError,
      ArithmeticError,
      BadMapError,
      FunctionClauseError,
      KeyError,
      Protocol.UndefinedError
    ] ->
      {:error, :invalid_usage_reserve}
  end

  defp amendments(registration) do
    original = registration["original"]
    authorization = original["authorization"]
    receipts = registration["amendments"]

    if is_list(receipts) and length(receipts) in 0..32 do
      Enum.reduce_while(
        receipts,
        {:ok, authorization["limits"], original["deadline_ms"], authorization["sha256"]},
        &advance/2
      )
      |> case do
        {:ok, limits, deadline, _sha} -> {:ok, limits, deadline}
        error -> error
      end
    else
      {:error, :invalid_study_amendment}
    end
  end

  defp advance(receipt, {:ok, prior, deadline, sha}) do
    current = receipt["limits"]

    with :ok <- Contract.verify_digest(receipt, "sha256"),
         ^prior <- receipt["prior_limits"],
         ^sha <- receipt["previous_sha256"],
         true <- Enum.sort(Map.keys(current)) == Enum.sort(Map.keys(prior)),
         true <- Enum.all?(current, &increased?(&1, prior)),
         next = deadline + current["max_time_ms"] - prior["max_time_ms"],
         ^next <- receipt["deadline_ms"] do
      {:cont, {:ok, current, next, receipt["sha256"]}}
    else
      _invalid -> {:halt, {:error, :invalid_study_amendment}}
    end
  end

  defp increased?({key, value}, prior), do: is_integer(value) and value >= prior[key]

  defp verify(checkpoint, directory, limits) do
    with :ok <- Checkpoint.verify(checkpoint, Contract.sha256(directory), 8192),
         true <- checkpoint["job_budget"]["max_requests"] == limits["max_requests"],
         true <- checkpoint["limits"]["max_tokens"] == limits["max_tokens"],
         true <- checkpoint["limits"]["learning"] == Map.put(limits, "max_cost_usd", nil) do
      :ok
    else
      _invalid -> {:error, :invalid_study_registration}
    end
  end

  defp write(path, value) do
    value = Journal.seal(value)

    with true <- byte_size(Contract.encode!(value)) <= @maximum,
         :ok <- Journal.safe(path),
         :ok <- Installation.write(path, value),
         do: File.chmod(path, 0o600)
  end

  # The envelope has audit overhead, but its controller must fit the reader's
  # independent bound. Otherwise a successful persist could strand reopening.
  defp checkpoint_write(path, value, checkpoint) do
    if byte_size(Contract.encode!(checkpoint)) <= 4_194_304,
      do: write(path, value),
      else: {:error, :study_checkpoint_too_large}
  end

  defp read(path) do
    with :ok <- Journal.safe(path),
         {:ok, %{type: :regular, size: size}} when size <= @maximum <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} <- Contract.decode(bytes),
         :ok <- Contract.verify_digest(value, "sha256"),
         do: {:ok, value}
  end
end
